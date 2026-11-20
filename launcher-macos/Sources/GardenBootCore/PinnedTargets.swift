import Foundation

/// Apps with their own animation (TARGETS.md `animation`) are not affected when the user switches the current
/// animation. The settings window and the menu say so, and offer to let them follow the current animation again.
public enum PinnedTargets {
    /// Enabled apps whose own animation is something other than `activeID`.
    public static func unaffected(activeID: String?, targets: [ApplicationTarget]) -> [ApplicationTarget] {
        targets.filter { $0.enabled && $0.animation != nil && $0.animation != activeID }
    }

    /// The same apps with every per-app choice cleared, so they all follow the current animation.
    public static func followingCurrent(_ targets: [ApplicationTarget]) -> [ApplicationTarget] {
        targets.map { var target = $0; target.animation = nil; return target }
    }

    /// e.g. "ChatGPT 单独指定了「雷电将军 · 花园」，不跟随切换。" (at most two names, then a count).
    public static func hint(_ pinned: [ApplicationTarget], packName: (String) -> String) -> String? {
        guard !pinned.isEmpty else { return nil }
        let named = pinned.prefix(2).map { "\($0.name) 单独指定了「\(packName($0.animation ?? ""))」" }.joined(separator: "，")
        let more = pinned.count > 2 ? "，另有 \(pinned.count - 2) 个应用也单独指定了动画" : ""
        return named + more + "，不跟随切换。"
    }
}
