import XCTest
import CoreGraphics
@testable import GardenBootCore

final class OverlayTests: XCTestCase {
    // MARK: Launch frame

    func testLaunchFrameStaysInsideTheCentralShareAndKeepsAspect() {
        let screens = [CGRect(x: 0, y: 0, width: 1512, height: 944), CGRect(x: -900, y: 500, width: 700, height: 300),
                       CGRect(x: 1512, y: -200, width: 1080, height: 1920), CGRect(x: 0, y: 0, width: 5120, height: 2160)]
        for visible in screens {
            for aspect: CGFloat in [16.0 / 9.0, 4.0 / 3.0, 2.39] {
                let frame = OverlayGeometry.launchFrame(in: visible, aspect: aspect)
                XCTAssertTrue(visible.contains(frame), "\(visible) \(aspect)")
                XCTAssertLessThanOrEqual(frame.width, visible.width * OverlayGeometry.launchCoverage + 1)
                XCTAssertLessThanOrEqual(frame.height, visible.height * OverlayGeometry.launchCoverage + 1)
                XCTAssertLessThanOrEqual(frame.width, OverlayGeometry.launchMaxWidth + 1)
                XCTAssertEqual(frame.width / frame.height, aspect, accuracy: 0.02)
                XCTAssertEqual(frame.midX, visible.midX, accuracy: 1)
                XCTAssertEqual(frame.midY, visible.midY, accuracy: 1)
                XCTAssertEqual(frame, frame.integral)
            }
        }
    }

    func testLaunchFrameRejectsDegenerateInput() {
        XCTAssertEqual(OverlayGeometry.launchFrame(in: .zero), .zero)
        XCTAssertEqual(OverlayGeometry.launchFrame(in: CGRect(x: 0, y: 0, width: 800, height: 600), aspect: 0), .zero)
        XCTAssertEqual(OverlayGeometry.launchFrame(in: CGRect(x: 0, y: 0, width: 800, height: 600), aspect: .nan), .zero)
    }

    func testEasingAndInterpolation() {
        XCTAssertEqual(OverlayGeometry.ease(-1), 0)
        XCTAssertEqual(OverlayGeometry.ease(0), 0)
        XCTAssertEqual(OverlayGeometry.ease(0.5), 0.5, accuracy: 1e-9)
        XCTAssertEqual(OverlayGeometry.ease(1), 1)
        XCTAssertEqual(OverlayGeometry.ease(3), 1)
        XCTAssertLessThan(OverlayGeometry.ease(0.1), 0.1, "slow start")
        let a = CGRect(x: 0, y: 0, width: 100, height: 50)
        let b = CGRect(x: 200, y: 100, width: 300, height: 150)
        XCTAssertEqual(OverlayGeometry.interpolate(from: a, to: b, progress: 0), a)
        XCTAssertEqual(OverlayGeometry.interpolate(from: a, to: b, progress: 1), b)
        XCTAssertEqual(OverlayGeometry.interpolate(from: a, to: b, progress: 0.5), CGRect(x: 100, y: 50, width: 200, height: 100))
    }

    // MARK: Window picker

    private func record(_ pid: Int32, layer: Int = 0, opacity: Double = 1, _ rect: CGRect) -> WindowRecord {
        WindowRecord(ownerPID: pid, layer: layer, opacity: opacity, bounds: rect)
    }

    func testPicksTheFrontmostOrdinaryWindowOfTheTarget() {
        let list = [
            record(7, CGRect(x: 0, y: 0, width: 2000, height: 1200)),              // another app, in front
            record(42, layer: 25, CGRect(x: 0, y: 0, width: 400, height: 300)),     // target's status-level helper
            record(42, opacity: 0.2, CGRect(x: 0, y: 0, width: 900, height: 700)),  // still fading in
            record(42, CGRect(x: 10, y: 10, width: 200, height: 120)),             // too small (splash)
            record(42, CGRect(x: 100, y: 40, width: 1000, height: 700)),           // the main window
            record(42, CGRect(x: 0, y: 0, width: 1400, height: 900)),              // larger but behind
        ]
        let frame = WindowPicker.mainWindowFrame(of: 42, in: list, primaryDisplayHeight: 1000)
        XCTAssertEqual(frame, CGRect(x: 100, y: 1000 - 740, width: 1000, height: 700))
        XCTAssertNil(WindowPicker.mainWindowFrame(of: 99, in: list, primaryDisplayHeight: 1000))
        XCTAssertNil(WindowPicker.mainWindowFrame(of: 42, in: [], primaryDisplayHeight: 1000))
    }

    func testParsesWindowServerDictionaries() {
        let info: [String: Any] = [
            kCGWindowOwnerPID as String: NSNumber(value: 42),
            kCGWindowLayer as String: NSNumber(value: 0),
            kCGWindowAlpha as String: NSNumber(value: 1.0),
            kCGWindowBounds as String: CGRect(x: 5, y: 6, width: 700, height: 500).dictionaryRepresentation,
        ]
        XCTAssertEqual(WindowRecord(windowInfo: info), record(42, CGRect(x: 5, y: 6, width: 700, height: 500)))
        var missingBounds = info
        missingBounds[kCGWindowBounds as String] = nil
        XCTAssertNil(WindowRecord(windowInfo: missingBounds))
        var noLayer = info
        noLayer[kCGWindowLayer as String] = nil
        XCTAssertEqual(WindowRecord(windowInfo: noLayer)?.layer, Int.max, "unknown layer is never treated as a normal window")
    }

    // MARK: Event log

    func testEventLogAppendsAndRotates() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("log-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let log = EventLog(directory: dir, limit: 200)
        log.write("first")
        log.write("second")
        var text = try String(contentsOf: log.url, encoding: .utf8)
        XCTAssertEqual(text.split(separator: "\n").count, 2)
        XCTAssertTrue(text.hasSuffix(" second\n"))
        for i in 0..<10 { log.write("event-\(i)-" + String(repeating: "x", count: 20)) }
        text = try String(contentsOf: log.url, encoding: .utf8)
        XCTAssertLessThanOrEqual(text.utf8.count, 200)
        XCTAssertTrue(text.contains("event-9-"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: log.previousURL.path))
    }
}
