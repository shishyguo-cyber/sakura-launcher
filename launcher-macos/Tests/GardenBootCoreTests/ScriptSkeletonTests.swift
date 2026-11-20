import CoreGraphics
import CoreText
import Foundation
import XCTest
@testable import GardenBootCore

final class ScriptSkeletonTests: XCTestCase {
    /// A thick horizontal bar thins to one stroke running its length.
    func testThickBarBecomesOneCentredStroke() {
        let (w, h) = (200, 60)
        var mask = [UInt8](repeating: 0, count: w * h)
        for y in 22..<38 { for x in 20..<180 { mask[y * w + x] = 255 } }
        let strokes = ScriptSkeleton.strokes(mask: mask, width: w, height: h, unit: 100)
        XCTAssertEqual(strokes.count, 1)
        let stroke = strokes[0]
        XCTAssertGreaterThan(ScriptSkeleton.length(stroke), 120)
        for point in stroke { XCTAssertEqual(point.y, 29.5, accuracy: 3) }
        XCTAssertLessThan(stroke.first!.x, stroke.last!.x, "the pen writes left to right")
    }

    /// Separate marks come out left to right, and a small isolated dot (the dot of an i) is kept.
    func testStrokesFollowWritingOrderAndKeepDots() {
        let (w, h) = (300, 120)
        var mask = [UInt8](repeating: 0, count: w * h)
        func box(_ x0: Int, _ y0: Int, _ x1: Int, _ y1: Int) { for y in y0..<y1 { for x in x0..<x1 { mask[y * w + x] = 255 } } }
        box(200, 60, 280, 70)   // right bar
        box(20, 60, 100, 70)    // left bar
        box(140, 20, 150, 29)   // dot, far from both bars
        let strokes = ScriptSkeleton.strokes(mask: mask, width: w, height: h, unit: 100)
        XCTAssertEqual(strokes.count, 3)
        let starts = strokes.map { $0.map(\.x).min()! }
        XCTAssertEqual(starts, starts.sorted())
    }

    func testEmptyOrMalformedMaskGivesNoStrokes() {
        XCTAssertTrue(ScriptSkeleton.strokes(mask: [], width: 0, height: 0, unit: 100).isEmpty)
        XCTAssertTrue(ScriptSkeleton.strokes(mask: [UInt8](repeating: 0, count: 100), width: 10, height: 10, unit: 100).isEmpty)
        XCTAssertTrue(ScriptSkeleton.strokes(mask: [1, 2, 3], width: 10, height: 10, unit: 100).isEmpty)
    }

    /// The real face used by style C turns "welcome" into a handful of connected pen strokes spanning the word.
    func testScriptFaceProducesWritableStrokes() throws {
        let size: CGFloat = 150
        let font = CTFontCreateWithName("BradleyHandITCTT-Bold" as CFString, size, nil)
        try XCTSkipUnless((CTFontCopyPostScriptName(font) as String).hasPrefix("BradleyHand"), "Bradley Hand not installed")
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: "welcome", attributes: [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorFromContextAttributeName as String): true,
        ]))
        var ascent: CGFloat = 0, descent: CGFloat = 0
        let advance = CTLineGetTypographicBounds(line, &ascent, &descent, nil)
        let w = Int(advance) + 72, h = Int(ascent + descent) + 72
        var mask = [UInt8](repeating: 0, count: w * h)
        mask.withUnsafeMutableBytes { buffer in
            let context = CGContext(data: buffer.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w,
                                    space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)!
            context.setFillColor(gray: 1, alpha: 1)
            context.textPosition = CGPoint(x: 36, y: 36 + descent)
            CTLineDraw(line, context)
        }
        let strokes = ScriptSkeleton.strokes(mask: mask, width: w, height: h, unit: Double(size))
        XCTAssertGreaterThan(strokes.count, 0)
        XCTAssertLessThan(strokes.count, 25, "junction leftovers should be cleaned up")
        let xs = strokes.flatMap { $0.map(\.x) }
        XCTAssertGreaterThan(xs.max()! - xs.min()!, advance * 0.85, "the strokes cover the whole word")
        XCTAssertGreaterThan(strokes.map(ScriptSkeleton.length).reduce(0, +), advance * 2)
    }

    func testScriptTextAndEmojiFallback() {
        XCTAssertEqual(Greeting.scriptText(name: "shishyguo"), "welcome shishyguo")
        XCTAssertEqual(Greeting.scriptText(name: nil), "welcome")
        XCTAssertEqual(Greeting.scriptText(name: ""), "welcome")
        XCTAssertTrue(Greeting.scriptCanWrite(name: "shishyguo"))
        XCTAssertTrue(Greeting.scriptCanWrite(name: nil))
        XCTAssertTrue(Greeting.scriptCanWrite(name: "小樱"))
        XCTAssertTrue(Greeting.scriptCanWrite(name: "Guo 2"))
        XCTAssertFalse(Greeting.scriptCanWrite(name: "小樱🌸"))
        XCTAssertFalse(Greeting.scriptCanWrite(name: "❤️"))
    }
}
