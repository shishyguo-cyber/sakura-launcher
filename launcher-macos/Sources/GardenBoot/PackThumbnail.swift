import AppKit
import AVFoundation
import CryptoKit
import SwiftUI
import GardenBootCore

/// First-frame cache lives in the system cache directory, never in the pack.
@MainActor final class PackThumbnail: ObservableObject {
    @Published var image: NSImage?
    private var generator: AVAssetImageGenerator?
    private var request = UUID()

    func load(_ pack: InstalledPack) {
        cancel(); image = nil
        if let cover = pack.manifest.cover { image = NSImage(contentsOf: pack.url(for: cover)); return }
        let video = pack.url(for: pack.layout.intro ?? pack.layout.loop ?? pack.layout.final)
        let modified = (try? video.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)?.timeIntervalSince1970 ?? 0
        let key = "\(pack.id)|\(video.path)|\(modified)"
        let hash = SHA256.hash(data: Data(key.utf8)).map { String(format: "%02x", $0) }.joined()
        let directory = (argument(after: "--test-root") != nil ? Support.root.appendingPathComponent("Cache") :
            FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0])
            .appendingPathComponent("GardenBoot/Thumbnails", isDirectory: true)
        let cache = directory.appendingPathComponent(hash + ".png")
        if let cached = NSImage(contentsOf: cache) { image = cached; return }
        let token = request
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: video))
        generator.appliesPreferredTrackTransform = true
        self.generator = generator
        generator.generateCGImagesAsynchronously(forTimes: [NSValue(time: .zero)]) { [weak self] _, cg, _, result, _ in
            Task { @MainActor in
                guard let self, self.request == token else { return }
                self.request = UUID(); self.generator = nil
                guard result == .succeeded, let cg else { return }
                self.image = NSImage(cgImage: cg, size: .zero)
                if !CommandLine.arguments.contains("--render-settings"),
                   let data = NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:]) {
                    try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                    try? data.write(to: cache, options: .atomic)
                }
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            guard let self, self.request == token else { return }
            self.cancel() // Keep the named placeholder when a frame cannot be read in two seconds.
        }
    }
    func cancel() { request = UUID(); generator?.cancelAllCGImageGeneration(); generator = nil }
}

struct PackThumbnailView: View {
    let pack: InstalledPack?
    let name: String
    @StateObject private var thumbnail = PackThumbnail()
    private var version: String {
        guard let pack else { return name }
        let url = pack.url(for: pack.manifest.cover ?? pack.layout.intro ?? pack.layout.loop ?? pack.layout.final)
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        return "\(pack.id)|\(url.path)|\(attributes?[.modificationDate] as? Date ?? .distantPast)|\(attributes?[.size] as? NSNumber ?? 0)"
    }
    var body: some View {
        ZStack {
            Rectangle().fill(Theme.accentSoft)
            if let image = thumbnail.image {
                GeometryReader { geometry in
                    Image(nsImage: image).resizable().scaledToFill()
                        .frame(width: geometry.size.width, height: geometry.size.height).clipped()
                }
            } else {
                VStack(spacing: 8) {
                    Image(nsImage: FlowerIcon.image()).resizable().frame(width: 28, height: 28)
                    Text(name).font(.callout).lineLimit(2).multilineTextAlignment(.center)
                }.padding().foregroundStyle(Theme.textSecondary)
            }
        }
        .aspectRatio(16 / 9, contentMode: .fit).frame(maxWidth: .infinity).clipped().cornerRadius(8)
        .accessibilityLabel("\(name)封面")
        .task(id: version) { if let pack { thumbnail.load(pack) } }
        .onDisappear { thumbnail.cancel() }
    }
}
