namespace GardenBoot.Core;

/// <summary>Transient facts about one saved target; not a persisted format.</summary>
public sealed class PlaybackStatusInput
{
    public bool Preparing { get; set; } = false;
    public bool Playing { get; set; } = false;
    public bool Preview { get; set; } = false;
    public bool HasTarget { get; set; } = true;
    public bool TargetEnabled { get; set; } = true;
    public bool Paused { get; set; } = false;
    public bool ReduceMotion { get; set; } = false;
    public bool AllowMotion { get; set; } = false;
    public bool LoginGrace { get; set; } = false;
    public bool Hidden { get; set; } = false;
    public bool Snoozed { get; set; } = false;
    public bool PlayedToday { get; set; } = false;
    public bool HasPack { get; set; } = true;
    public bool Failed { get; set; } = false;
    public bool Running { get; set; } = false;
}

public sealed record PlaybackStatusReason(string Code, string Title, string Detail, string Action)
{
    private static readonly IReadOnlyDictionary<string, PlaybackStatusReason> Values = new Dictionary<string, PlaybackStatusReason>
    {
        ["preparing"] = new("preparing", "正在准备动画", "动画库或播放器正在准备，请稍候。", "none"),
        ["playing"] = new("playing", "正在播放动画", "当前有一段动画正在播放；其它应用的启动不会打断它。", "none"),
        ["preview"] = new("preview", "正在预览动画", "预览使用当前草稿，不消耗每日播放次数，也不会启动目标应用。", "none"),
        ["noTargets"] = new("noTargets", "还没有选择应用", "到应用页添加一个目标，保存后 Sakura 才会开始监听它。", "targets"),
        ["disabled"] = new("disabled", "此应用尚未启用", "到应用页开启该目标并保存，之后的冷启动才会触发动画。", "targets"),
        ["paused"] = new("paused", "自动播放已暂停", "暂停期间仍可手动预览。取消暂停只会更改自动播放开关。", "unpause"),
        ["reduceMotion"] = new("reduceMotion", "已遵循系统动态效果设置", "系统减少动态效果时默认不自动播放；仍可手动预览，或在菜单中更改覆盖选项。", "none"),
        ["loginGrace"] = new("loginGrace", "登录后稍候开始播放", "登录初期会暂时忽略自动播放，避免开机时连续出现动画。", "none"),
        ["hidden"] = new("hidden", "应用当前处于隐藏状态", "隐藏或最小化状态会跳过自动播放；可以手动预览查看效果。", "none"),
        ["snoozed"] = new("snoozed", "临时暂停中", "暂停到期后自动恢复，也可以提前结束临时暂停。", "unsnooze"),
        ["playedToday"] = new("playedToday", "今天已经播放过", "当前规则为每天首次，各应用独立记录；手动预览仍然可用。", "playback"),
        ["noPack"] = new("noPack", "没有可用动画", "请在动画页导入可播放的包，或检查视频文件是否已被移动或删除。", "animation"),
        ["failed"] = new("failed", "最近一次播放失败", "请检查或重新导入对应动画；预览成功后会清除本次失败提示。", "animation"),
        ["running"] = new("running", "应用已经在运行", "Sakura 不会为已有进程补播；完全退出该应用后再启动才会触发。", "none"),
        ["ready"] = new("ready", "等待下一次启动", "监听使用已保存的设置；下次从原有入口冷启动该应用时按规则播放。", "none"),
    };

    public static PlaybackStatusReason Resolve(PlaybackStatusInput input)
    {
        if (input.Playing && input.Preview) return Values["preview"];
        if (input.Playing) return Values["playing"];
        if (input.Preparing) return Values["preparing"];
        if (!input.HasTarget) return Values["noTargets"];
        if (!input.TargetEnabled) return Values["disabled"];
        if (input.Paused) return Values["paused"];
        if (input.ReduceMotion && !input.AllowMotion) return Values["reduceMotion"];
        if (input.LoginGrace) return Values["loginGrace"];
        if (input.Hidden) return Values["hidden"];
        if (input.Snoozed) return Values["snoozed"];
        if (input.Failed && input.HasPack) return Values["failed"];
        if (input.PlayedToday) return Values["playedToday"];
        if (!input.HasPack) return Values["noPack"];
        if (input.Running) return Values["running"];
        return Values["ready"];
    }
}
