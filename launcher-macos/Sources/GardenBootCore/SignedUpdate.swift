import Foundation
import CryptoKit

public enum SignedUpdate {
    public static let publicKey = "MFkwEwYHKoZIzj0CAQYIKoZIzj0DAQcDQgAELfF7XIzY6fqIOYOf7aN5SViuJ7PKHuKfsTPVCCp2EQv1yceqVYpgpHPG/ksrrPI9Qb/taY3F45xepyT4zB5ntA=="
    public static let maxArchive = 512 * 1024 * 1024
    public static let maxExpanded = 2 * 1024 * 1024 * 1024
    public enum Failure: String, Error, LocalizedError {
        case version, signature, corrupt, space, permission, structure, network, replacement, startup
        public var errorDescription: String? {
            switch self {
            case .version: return "版本无效或不是更新版本。"
            case .signature: return "更新签名验证失败。"
            case .corrupt: return "更新文件损坏或下载不完整。"
            case .space: return "磁盘空间不足，请至少留出 5 GB。"
            case .permission: return "应用所在目录不可写，请手动下载并替换。"
            case .structure: return "更新包的程序结构或版本不正确。"
            case .network: return "更新下载失败，请检查网络后重试。"
            case .replacement: return "替换失败，已保留或恢复旧版。"
            case .startup: return "新版未能正常启动，已恢复旧版。"
            }
        }
    }
    public struct Manifest: Codable {
        public var format: Int
        public var version: String
        public var platform: String
        public var bytes: Int
        public var sha256: String
        public var signature: String
        public var message: Data { Data("Sakura Update v1\n\(version)\n\(platform)\n\(bytes)\n\(sha256)\n".utf8) }
    }
    public static func asset(version: String, current: String, platform: String) throws -> URL {
        guard UpdateRules.parse(version)?.text == version, !version.contains("/"),
              (UpdateRules.compare(version, current) ?? 0) > 0, ["macOS", "windows-x64"].contains(platform) else { throw Failure.version }
        return URL(string: "https://github.com/shishyguo-cyber/sakura-launcher/releases/download/v\(version)/Sakura-\(version)-\(platform).zip")!
    }
    public static func verify(manifest: Data, payload: Data, version: String, current: String, platform: String) throws {
        _ = try asset(version: version, current: current, platform: platform)
        guard manifest.count <= 16384, let m = try? JSONDecoder().decode(Manifest.self, from: manifest), m.format == 1,
              m.version == version, m.platform == platform, m.bytes > 0, m.bytes <= maxArchive,
              m.sha256.count == 64, m.sha256.allSatisfy({ "0123456789abcdef".contains($0) }),
              let sig = Data(base64Encoded: m.signature),
              let signature = try? P256.Signing.ECDSASignature(derRepresentation: sig),
              let key = try? P256.Signing.PublicKey(derRepresentation: Data(base64Encoded: publicKey)!),
              key.isValidSignature(signature, for: m.message) else { throw Failure.signature }
        guard payload.count == m.bytes, SHA256.hash(data: payload).map({ String(format: "%02x", $0) }).joined() == m.sha256 else { throw Failure.corrupt }
    }
    /// All ZIP entries are checked before invoking the OS extractor (no symlinks, traversal, zip64, bombs or aliases).
    public static func checkZip(_ data: Data) throws {
        let a = [UInt8](data)
        func n(_ p: Int, _ size: Int) throws -> Int {
            guard p >= 0, p + size <= a.count else { throw Failure.structure }
            return (0..<size).reduce(0) { $0 | Int(a[p + $1]) << ($1 * 8) }
        }
        guard a.count >= 22 else { throw Failure.structure }
        var end: Int?
        for i in stride(from: a.count - 22, through: max(0, a.count - 65557), by: -1) {
            if try n(i, 4) == 0x06054b50 { end = i; break }
        }
        guard let e = end, try n(e+4, 4) == 0 else { throw Failure.structure }
        let count = try n(e+10, 2); var p = try n(e+16, 4); var total = 0; var seen = Set<String>()
        guard count > 0, count < 65535 else { throw Failure.structure }
        for _ in 0..<count {
            guard try n(p,4) == 0x02014b50, try n(p+8,2) & 1 == 0 else { throw Failure.structure }
            let size = try n(p+24,4), length = try n(p+28,2), extra = try n(p+30,2), comment = try n(p+32,2), mode = try n(p+38,4) >> 16
            guard length > 0, p+46+length <= a.count, mode & 0xf000 != 0xa000,
                  let name = String(bytes: a[(p+46)..<(p+46+length)], encoding: .utf8),
                  !name.hasPrefix("/"), !name.contains("\\"), !name.contains(":"), !name.contains("\0"),
                  !name.split(separator: "/").contains(where: { $0 == ".." || $0 == "." }),
                  seen.insert(name.lowercased()).inserted else { throw Failure.structure }
            total += size; guard total <= maxExpanded else { throw Failure.space }
            p += 46+length+extra+comment
        }
    }
}
