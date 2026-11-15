import Foundation

/// Transient facts about one saved target; never persisted into user settings.
public struct PlaybackStatusInput: Codable, Sendable {
    public var preparing = false
    public var playing = false
    public var preview = false
    public var hasTarget = true
    public var targetEnabled = true
    public var paused = false
    public var reduceMotion = false
    public var allowMotion = false
    public var loginGrace = false
    public var hidden = false
    public var snoozed = false
    public var playedToday = false
    public var hasPack = true
    public var failed = false
    public var running = false
    public init() {}
}

public enum PlaybackStatusReason: String, Sendable {
    case preparing, playing, preview, noTargets, disabled, paused, reduceMotion, loginGrace, hidden, snoozed, playedToday, noPack, failed, running, ready

    public static func resolve(_ input: PlaybackStatusInput) -> Self {
        if input.playing && input.preview { return .preview }
        if input.playing { return .playing }
        if input.preparing { return .preparing }
        if !input.hasTarget { return .noTargets }
        if !input.targetEnabled { return .disabled }
        if input.paused { return .paused }
        if input.reduceMotion && !input.allowMotion { return .reduceMotion }
        if input.loginGrace { return .loginGrace }
        if input.hidden { return .hidden }
        if input.snoozed { return .snoozed }
        if input.failed && input.hasPack { return .failed }
        if input.playedToday { return .playedToday }
        if !input.hasPack { return .noPack }
        if input.running { return .running }
        return .ready
    }
    public var title: String {
        switch self {
        case .preparing: return "正在准备动画"
        case .playing: return "正在播放动画"
        case .preview: return "正在预览动画"
        case .noTargets: return "还没有选择应用"
        case .disabled: return "此应用尚未启用"
        case .paused: return "自动播放已暂停"
        case .reduceMotion: return "已遵循系统动态效果设置"
        case .loginGrace: return "登录后稍候开始播放"
        case .hidden: return "应用当前处于隐藏状态"
        case .snoozed: return "临时暂停中"
        case .playedToday: return "今天已经播放过"
        case .noPack: return "没有可用动画"
        case .failed: return "最近一次播放失败"
        case .running: return "应用已经在运行"
        case .ready: return "等待下一次启动"
        }
    }
    public var detail: String {
        switch self {
        case .preparing: return "动画库或播放器正在准备，请稍候。"
        case .playing: return "当前有一段动画正在播放；其它应用的启动不会打断它。"
        case .preview: return "预览使用当前草稿，不消耗每日播放次数，也不会启动目标应用。"
        case .noTargets: return "到应用页添加一个目标，保存后 Sakura 才会开始监听它。"
        case .disabled: return "到应用页开启该目标并保存，之后的冷启动才会触发动画。"
        case .paused: return "暂停期间仍可手动预览。取消暂停只会更改自动播放开关。"
        case .reduceMotion: return "系统减少动态效果时默认不自动播放；仍可手动预览，或在菜单中更改覆盖选项。"
        case .loginGrace: return "登录初期会暂时忽略自动播放，避免开机时连续出现动画。"
        case .hidden: return "隐藏或最小化状态会跳过自动播放；可以手动预览查看效果。"
        case .snoozed: return "暂停到期后自动恢复，也可以提前结束临时暂停。"
        case .playedToday: return "当前规则为每天首次，各应用独立记录；手动预览仍然可用。"
        case .noPack: return "请在动画页导入可播放的包，或检查视频文件是否已被移动或删除。"
        case .failed: return "请检查或重新导入对应动画；预览成功后会清除本次失败提示。"
        case .running: return "Sakura 不会为已有进程补播；完全退出该应用后再启动才会触发。"
        case .ready: return "监听使用已保存的设置；下次从原有入口冷启动该应用时按规则播放。"
        }
    }
    public var action: String {
        switch self {
        case .preparing: return "none"
        case .playing: return "none"
        case .preview: return "none"
        case .noTargets: return "targets"
        case .disabled: return "targets"
        case .paused: return "unpause"
        case .reduceMotion: return "none"
        case .loginGrace: return "none"
        case .hidden: return "none"
        case .snoozed: return "unsnooze"
        case .playedToday: return "playback"
        case .noPack: return "animation"
        case .failed: return "animation"
        case .running: return "none"
        case .ready: return "none"
        }
    }
}
