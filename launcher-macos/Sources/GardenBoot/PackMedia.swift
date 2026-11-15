import AVFoundation
import GardenBootCore
import ImageIO

/// AVFoundation side of launch packs: one loader for import checks and for playback preloading.
enum PackMedia {
    struct Loaded: @unchecked Sendable {
        let asset: AVURLAsset
        let duration: Double
        let videoAspect: CGFloat
    }

    /// Opens a segment and proves it has a decodable picture of positive, finite length.
    static func load(_ url: URL) async throws -> Loaded {
        let asset = AVURLAsset(url: url, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
        let (isPlayable, length) = try await asset.load(.isPlayable, .duration)
        let pictureTracks = try await asset.loadTracks(withMediaType: .video)
        let seconds = CMTimeGetSeconds(length)
        guard isPlayable, !pictureTracks.isEmpty, seconds.isFinite, seconds > 0 else {
            throw PackError.invalidMedia(url.lastPathComponent)
        }
        let track = pictureTracks[0]
        let (naturalSize, transform, descriptions) = try await track.load(.naturalSize, .preferredTransform, .formatDescriptions)
        // Presentation dimensions honor clean aperture and non-square pixels; the track transform
        // then supplies the displayed orientation, including portrait videos stored sideways.
        let pictureSize = descriptions.first.map {
            CMVideoFormatDescriptionGetPresentationDimensions($0, usePixelAspectRatio: true, useCleanAperture: true)
        } ?? naturalSize
        let displayed = CGRect(origin: .zero, size: pictureSize).applying(transform).size
        let aspect = displayed.width / displayed.height
        return Loaded(asset: asset, duration: seconds, videoAspect: aspect)
    }

    static let imageProbe: ImageProbe = { url in
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return false }
        return CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary) != nil
    }

    @MainActor static func playableLibrary(_ library: PackLibrary) async -> (packs: [InstalledPack], problems: [String: String]) {
        let installed = library.installed()
        var packs: [InstalledPack] = [], problems = installed.problems
        for pack in installed.packs {
            do {
                for file in pack.manifest.segments.values { _ = try await load(pack.url(for: file)) }
                if let cover = pack.manifest.cover, try await !imageProbe(pack.url(for: cover)) {
                    throw PackError.invalidCover("\(cover) 无法解码为图片")
                }
                packs.append(pack)
            } catch { problems[pack.id] = error.localizedDescription }
        }
        return (packs, problems)
    }

    /// `MediaProbe` used by `PackLibrary` for bundled packs, imports and v1 migration.
    static let probe: MediaProbe = { url in
        MediaInfo(duration: try await load(url).duration, hasVideo: true)
    }
}
