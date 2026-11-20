import AppKit
import AVFoundation
import GardenBootCore
import Metal
import QuartzCore

/// Review command: renders a greeting offscreen (CARenderer → Metal texture) at full frame rate into an MP4.
/// Nothing is put on screen, so checking an animation never covers the windows the user is working in.
///
///     GardenBoot --render-greeting out.mp4 [--greeting-style script|pen|sweep] [--greeting-name NAME]
///                [--greeting-light dawn|daylight|dusk|moonlight] [--greeting-size 1920x1080]
///                [--greeting-exit-at 3.4] [--greeting-length 4.4] [--greeting-still]
enum GreetingRecorder {
    static var requested: Bool { CommandLine.arguments.contains("--render-greeting") }

    enum Failure: LocalizedError {
        case arguments(String), metal, writer(String), timeout
        var errorDescription: String? {
            switch self {
            case .arguments(let message): return message
            case .metal: return "无法创建离屏 Metal 渲染目标。"
            case .writer(let message): return "视频写入失败：\(message)"
            case .timeout: return "问候画面在 5 秒内没有准备好。"
            }
        }
    }

    @MainActor
    static func record() async throws {
        guard let output = argument(after: "--render-greeting") else { throw Failure.arguments("--render-greeting 后需要输出路径。") }
        let style = try argument(after: "--greeting-style").map {
            guard let style = Greeting.Style(rawValue: $0) else { throw Failure.arguments("--greeting-style 仅支持 script、pen、sweep。") }
            return style
        } ?? .script
        let light = argument(after: "--greeting-light").flatMap(Greeting.Light.init(rawValue:)) ?? .dusk
        let name = try Greeting.normalizedName(argument(after: "--greeting-name"))
        let still = CommandLine.arguments.contains("--greeting-still")
        let pieces = (argument(after: "--greeting-size") ?? "1920x1080").split(separator: "x").compactMap { Int($0) }
        guard pieces.count == 2, (320...3840).contains(pieces[0]), (240...2160).contains(pieces[1]) else {
            throw Failure.arguments("--greeting-size 格式如 1920x1080。")
        }
        let (width, height) = (pieces[0] / 2 * 2, pieces[1] / 2 * 2)
        let exitAt = argument(after: "--greeting-exit-at").flatMap(Double.init) ?? (style == .script ? 3.4 : 2.6)
        let length = argument(after: "--greeting-length").flatMap(Double.init) ?? exitAt + 1.0

        func note(_ m: String) { if ProcessInfo.processInfo.environment["SAKURA_RENDER_DEBUG"] != nil { FileHandle.standardError.write(Data("[render] \(m)\n".utf8)) } }
        note("start style=\(style.rawValue)")
        let view: NSView & GreetingRendering
        if style == .script, Greeting.scriptCanWrite(name: name) {
            note("making view")
            let script = ScriptGreetingView(name: name, still: still)
            note("view made")
            view = script
            let deadline = Date().addingTimeInterval(5)
            while !script.isReady {
                if Date() > deadline { throw Failure.timeout }
                note("waiting")
                try await Task.sleep(nanoseconds: 10_000_000)
            }
        } else {
            let fallback: Greeting.Style = style == .script ? .sweep : style
            view = GreetingOverlayView(light: light, name: name,
                                       treatment: still ? .still : .animated(fallback), opaque: true)
        }
        note("view ready")
        view.frame = CGRect(x: 0, y: 0, width: width, height: height)
        view.appearance = NSAppearance(named: .darkAqua)
        view.layoutSubtreeIfNeeded()
        guard let root = view.layer else { throw Failure.metal }

        guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else { throw Failure.metal }
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: width, height: height, mipmapped: false)
        descriptor.usage = [.renderTarget, .shaderRead]
        descriptor.storageMode = device.hasUnifiedMemory ? .shared : .managed
        guard let texture = device.makeTexture(descriptor: descriptor) else { throw Failure.metal }
        let renderer = CARenderer(mtlTexture: texture, options: [
            kCARendererColorSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
            kCARendererMetalCommandQueue: queue,
        ])
        renderer.layer = root
        renderer.bounds = CGRect(x: 0, y: 0, width: width, height: height)

        let url = URL(fileURLWithPath: output)
        try? FileManager.default.removeItem(at: url)
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: width, AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: 24_000_000],
        ])
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: width, kCVPixelBufferHeightKey as String: height,
        ])
        writer.add(input)
        guard writer.startWriting() else { throw Failure.writer(writer.error?.localizedDescription ?? "") }
        writer.startSession(atSourceTime: .zero)

        let fps = 60
        let frames = Int(length * Double(fps))
        let rowBytes = width * 4
        var scratch = [UInt8](repeating: 0, count: rowBytes * height)
        note("writing \(frames) frames")
        for frame in 0..<frames {
            let time = Double(frame) / Double(fps)
            view.render(time: time, exit: time >= exitAt ? time - exitAt : nil)
            renderer.beginFrame(atTime: CACurrentMediaTime(), timeStamp: nil)
            renderer.addUpdate(renderer.bounds)
            renderer.render()
            renderer.endFrame()
            guard let buffer = queue.makeCommandBuffer() else { throw Failure.metal }
            if texture.storageMode == .managed, let blit = buffer.makeBlitCommandEncoder() {
                blit.synchronize(resource: texture)
                blit.endEncoding()
            }
            finish(buffer)
            texture.getBytes(&scratch, bytesPerRow: rowBytes, from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0)

            while !input.isReadyForMoreMediaData { try await Task.sleep(nanoseconds: 2_000_000) }
            guard let pool = adaptor.pixelBufferPool else { throw Failure.writer("no pixel buffer pool") }
            var pixels: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pixels)
            guard let pixels else { throw Failure.writer("no pixel buffer") }
            CVPixelBufferLockBaseAddress(pixels, [])
            let base = CVPixelBufferGetBaseAddress(pixels)!.assumingMemoryBound(to: UInt8.self)
            let stride = CVPixelBufferGetBytesPerRow(pixels)
            scratch.withUnsafeBytes { source in
                // CARenderer draws y-up into the texture; video rows run top-down.
                for row in 0..<height {
                    memcpy(base + row * stride, source.baseAddress! + (height - 1 - row) * rowBytes, rowBytes)
                }
            }
            CVPixelBufferUnlockBaseAddress(pixels, [])
            adaptor.append(pixels, withPresentationTime: CMTime(value: CMTimeValue(frame), timescale: CMTimeScale(fps)))
        }
        input.markAsFinished()
        await writer.finishWriting()
        if writer.status != .completed { throw Failure.writer(writer.error?.localizedDescription ?? "status \(writer.status.rawValue)") }
    }

    /// Blocks until the GPU has finished the frame (kept synchronous; the recorder runs frame by frame).
    private static func finish(_ buffer: MTLCommandBuffer) {
        buffer.commit()
        buffer.waitUntilCompleted()
    }
}
