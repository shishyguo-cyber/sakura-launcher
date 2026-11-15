import AVFoundation
import GardenBootCore

// Compile alongside the production loader, without NSApplication or a graphical session.
let demo = URL(fileURLWithPath: CommandLine.arguments[1])
let output = URL(fileURLWithPath: CommandLine.arguments[2])
Task {
    do {
        for segment in ["intro", "loop", "outro"] {
            let loaded = try await PackMedia.load(demo.appendingPathComponent("\(segment).mp4"))
            precondition(abs(loaded.videoAspect - 16.0 / 9.0) < 1e-6)
        }
        let original = try await PackMedia.load(demo.appendingPathComponent("loop.mp4"))
        let composition = AVMutableComposition()
        let source = try await original.asset.loadTracks(withMediaType: .video)[0]
        let track = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid)!
        try track.insertTimeRange(CMTimeRange(start: .zero, duration: try await original.asset.load(.duration)), of: source, at: .zero)
        track.preferredTransform = CGAffineTransform(rotationAngle: .pi / 2)
        let exporter = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetPassthrough)!
        exporter.outputURL = output
        exporter.outputFileType = .mov
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            exporter.exportAsynchronously { continuation.resume() }
        }
        guard exporter.status == .completed else { throw exporter.error ?? CocoaError(.fileWriteUnknown) }
        let rotated = try await PackMedia.load(output)
        precondition(abs(rotated.videoAspect - 9.0 / 16.0) < 1e-6)
        let wide = try await PackMedia.load(demo.appendingPathComponent("outro.mp4"))
        precondition(abs(wide.videoAspect - 16.0 / 9.0) < 1e-6)
        print("video-fit media passed: three real 16:9 segments; passthrough 90-degree rotated 9:16 segment; next segment returns to 16:9")
        exit(0)
    } catch {
        fputs("video-fit media failed: \(error)\n", stderr)
        exit(1)
    }
}
dispatchMain()
