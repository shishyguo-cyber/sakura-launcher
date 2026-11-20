import XCTest
@testable import GardenBootCore

final class SignedUpdateTests: XCTestCase {
    func testGitHubConnectivityMessagesForCheckAndDownload() {
        let codes: [URLError.Code] = [
            .notConnectedToInternet, .cannotFindHost, .dnsLookupFailed, .cannotConnectToHost,
            .timedOut, .networkConnectionLost, .secureConnectionFailed, .serverCertificateHasBadDate,
            .serverCertificateUntrusted, .serverCertificateHasUnknownRoot, .serverCertificateNotYetValid,
            .clientCertificateRejected, .clientCertificateRequired,
        ]
        let expected = "连不上 GitHub，请确认这台电脑能打开 github.com 后重试。"
        for code in codes {
            let error = URLError(code)
            XCTAssertEqual(UpdateRules.checkFailureMessage(error), expected, "\(code)")
            XCTAssertEqual(SignedUpdate.failureMessage(error), expected, "\(code)")
        }
    }

    func testOtherUpdateErrorsRetainTheirMessages() {
        let errors: [Error] = [
            URLError(.badServerResponse), URLError(.cancelled), URLError(.httpTooManyRedirects),
            CocoaError(.fileWriteOutOfSpace),
            NSError(domain: "Test", code: URLError.timedOut.rawValue),
        ]
        for error in errors {
            XCTAssertEqual(UpdateRules.checkFailureMessage(error), "暂时无法检查更新，请稍后再试。")
            XCTAssertEqual(SignedUpdate.failureMessage(error), "更新失败：\(error.localizedDescription) 可去 GitHub 手动下载。")
        }
        XCTAssertEqual(SignedUpdate.failureMessage(SignedUpdate.Failure.signature), "更新失败：更新签名验证失败。 可去 GitHub 手动下载。")
        XCTAssertEqual(SignedUpdate.failureMessage(SignedUpdate.Failure.space), "更新失败：磁盘空间不足，请至少留出 5 GB。 可去 GitHub 手动下载。")
        XCTAssertEqual(SignedUpdate.failureMessage(SignedUpdate.Failure.network), "更新失败：更新下载失败，请检查网络后重试。 可去 GitHub 手动下载。")
    }

    func testRejectsDowngradeAndUnsafeVersions() throws {
        XCTAssertThrowsError(try SignedUpdate.asset(version: "0.2.0-preview.7", current: "0.2.0-preview.7", platform: "macOS"))
        XCTAssertThrowsError(try SignedUpdate.asset(version: "../bad", current: "0.1.0", platform: "macOS"))
        XCTAssertEqual(try SignedUpdate.asset(version: "0.2.0-preview.8", current: "0.2.0-preview.7", platform: "macOS").lastPathComponent, "Sakura-0.2.0-preview.8-macOS.zip")
    }
    func testLargePrereleaseAndCanonicalVersions() throws {
        XCTAssertEqual(UpdateRules.compare("0.2.0-preview.999999999999999999999999", "0.2.0-preview.8"), 1)
        XCTAssertThrowsError(try SignedUpdate.asset(version: "0.2.0-preview.8+metadata", current: "0.2.0-preview.7", platform: "macOS"))
    }
    func testSharedSignatures() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("launcher-spec/update-public-key.txt"), encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines), SignedUpdate.publicKey)
        let vectors = try JSONSerialization.jsonObject(with: Data(contentsOf: root.appendingPathComponent("launcher-spec/conformance/signed-updates.json"))) as! [[String: Any]]
        for v in vectors {
            let manifest = try JSONSerialization.data(withJSONObject: v["manifest"]!)
            do {
                try SignedUpdate.verify(manifest: manifest, payload: Data((v["payload"] as! String).utf8), version: v["version"] as! String, current: "0.2.0-preview.7", platform: v["platform"] as! String)
                XCTAssertEqual(v["valid"] as? Bool, true, v["name"] as! String)
                XCTAssertEqual(try SignedUpdate.asset(version: v["version"] as! String, current: "0.2.0-preview.7", platform: v["platform"] as! String).absoluteString, v["asset"] as? String)
                XCTAssertEqual(v["state"] as? String, "confirmed")
            } catch { XCTAssertEqual(v["valid"] as? Bool, false, v["name"] as! String); XCTAssertEqual((error as? SignedUpdate.Failure)?.rawValue, v["state"] as? String) }
        }
    }
}
