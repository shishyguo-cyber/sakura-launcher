import Foundation

public enum PlaybackRules {
    /// Hand focus back only if the user is still on the overlay or the target, and the target is alive.
    public static func shouldReturnFocus(frontmost: Int32?, player: Int32, target: Int32, targetAlive: Bool) -> Bool {
        targetAlive && (frontmost == player || frontmost == target)
    }
}
