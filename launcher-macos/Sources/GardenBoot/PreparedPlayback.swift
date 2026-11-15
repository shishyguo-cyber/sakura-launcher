import AVFoundation
import GardenBootCore

/// A transferable player, including its decoder and display layers. Idle warm-up owns exactly one.
@MainActor
final class PreparedPlayback {
    let segment: PackSegment
    let media: PackMedia.Loaded
    let player = AVQueuePlayer()
    let videoLayer = AVPlayerLayer()
    let backgroundVideoLayer = AVPlayerLayer()
    private(set) var looper: AVPlayerLooper?
    private(set) var isPrerolled = false
    private var statusWatch: NSKeyValueObservation?
    private var deadline: Timer?
    private var preparing = false
    private var disposed = false

    init(segment: PackSegment, media: PackMedia.Loaded, looping: Bool) {
        self.segment = segment
        self.media = media
        player.preventsDisplaySleepDuringVideoPlayback = false
        let item = AVPlayerItem(asset: media.asset)
        if looping {
            player.actionAtItemEnd = .advance
            looper = AVPlayerLooper(player: player, templateItem: item)
        } else {
            player.actionAtItemEnd = .pause
            player.insert(item, after: nil)
        }
        videoLayer.player = player
        backgroundVideoLayer.player = player
    }

    /// Preroll decodes at time zero without advancing the paused playhead or playing audio.
    func prepare(onReady: @escaping (Bool) -> Void) {
        player.isMuted = true
        deadline = Timer.scheduledTimer(withTimeInterval: 6, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.completePreparation(false, onReady: onReady) }
        }
        statusWatch = player.currentItem?.observe(\.status, options: [.initial, .new]) { [weak self] _, _ in
            Task { @MainActor in
                guard let self, !self.disposed, !self.preparing else { return }
                if self.player.currentItem?.status == .failed {
                    self.completePreparation(false, onReady: onReady)
                } else if self.player.currentItem?.status == .readyToPlay {
                    self.preparing = true
                    self.player.seek(to: .zero, toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] sought in
                        Task { @MainActor in
                            guard let self, !self.disposed, self.deadline != nil else { return }
                            guard sought else { self.completePreparation(false, onReady: onReady); return }
                            self.player.preroll(atRate: 1) { [weak self] ready in
                                Task { @MainActor in self?.completePreparation(ready, onReady: onReady) }
                            }
                        }
                    }
                }
            }
        }
    }

    private func completePreparation(_ ready: Bool, onReady: (Bool) -> Void) {
        guard !disposed, deadline != nil else { return }
        deadline?.invalidate(); deadline = nil
        statusWatch?.invalidate(); statusWatch = nil
        player.pause()
        isPrerolled = ready
        if !ready { dispose() }
        onReady(ready)
    }

    func dispose() {
        guard !disposed else { return }
        disposed = true
        deadline?.invalidate(); deadline = nil
        statusWatch?.invalidate(); statusWatch = nil
        player.cancelPendingPrerolls()
        player.pause()
        looper?.disableLooping(); looper = nil
        videoLayer.player = nil
        backgroundVideoLayer.player = nil
        player.removeAllItems()
    }
}
