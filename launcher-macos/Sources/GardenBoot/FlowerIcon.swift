import AppKit

/// Original five-petal geometry shared by the status item and its review export.
enum FlowerIcon {
    static func image() -> NSImage {
        let size = 36
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: size * 4, bitsPerPixel: 32)!
        let context = NSGraphicsContext(bitmapImageRep: bitmap)!.cgContext
        context.scaleBy(x: CGFloat(size), y: CGFloat(size))
        context.translateBy(x: 0.5, y: 0.5)
        context.setFillColor(NSColor.black.cgColor)
        for index in 0..<5 {
            context.saveGState()
            context.rotate(by: CGFloat(index) * 2 * .pi / 5)
            context.fillEllipse(in: CGRect(x: -0.145, y: 0.235 - 0.215, width: 0.29, height: 0.43))
            context.restoreGState()
        }
        context.setBlendMode(.clear)
        context.fillEllipse(in: CGRect(x: -0.085, y: -0.085, width: 0.17, height: 0.17))
        bitmap.size = NSSize(width: 18, height: 18)
        let image = NSImage(size: bitmap.size)
        image.addRepresentation(bitmap)
        image.isTemplate = true
        image.accessibilityDescription = "Sakura"
        return image
    }
}
