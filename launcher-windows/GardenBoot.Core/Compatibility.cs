namespace GardenBoot.Core;

/// <summary>Result of "测试一下" for one target app (launcher-spec/COMPATIBILITY.md §1).</summary>
public enum CompatVerdict { Good, SlowWindow, NoWindow, AlreadyRunning, NotOpened }

public static class CompatibilityRules
{
    public const double TestSeconds = 30;

    public static string LogName(this CompatVerdict v) => v switch
    {
        CompatVerdict.Good => "good", CompatVerdict.SlowWindow => "slowWindow", CompatVerdict.NoWindow => "noWindow",
        CompatVerdict.AlreadyRunning => "alreadyRunning", _ => "notOpened",
    };

    public static CompatVerdict? Parse(string? text) => text switch
    {
        "good" => CompatVerdict.Good, "slowWindow" => CompatVerdict.SlowWindow, "noWindow" => CompatVerdict.NoWindow,
        "alreadyRunning" => CompatVerdict.AlreadyRunning, "notOpened" => CompatVerdict.NotOpened, _ => null,
    };

    public static CompatVerdict Verdict(bool runningAtStart, bool coldStart, double? windowSeconds, double maxWait)
    {
        if (coldStart) return windowSeconds is not { } w ? CompatVerdict.NoWindow : w <= maxWait ? CompatVerdict.Good : CompatVerdict.SlowWindow;
        return runningAtStart ? CompatVerdict.AlreadyRunning : CompatVerdict.NotOpened;
    }

    /// <summary>The line shown under the app's name.</summary>
    public static string Message(CompatVerdict v, double? windowSeconds) => v switch
    {
        CompatVerdict.Good => $"适配良好：打开后约 {windowSeconds:0.0} 秒出现窗口",
        CompatVerdict.SlowWindow => $"窗口出现较慢（约 {windowSeconds:0.0} 秒），可调大“最长等待”",
        CompatVerdict.NoWindow => "检测到启动，但没找到主窗口（可能只在托盘运行）",
        CompatVerdict.AlreadyRunning => "它一直在后台运行，打开时不会产生新进程",
        _ => "没有检测到它被打开",
    };
}

/// <summary>
/// Detects an already-running app bringing a window back after having none (closed to tray / last window closed),
/// for targets with <c>playOnReappear</c> (COMPATIBILITY.md §2). Minimize/restore and hide/unhide do not count.
/// </summary>
public sealed class ReappearTracker
{
    public const double CollapseSeconds = 2;
    private double? since;
    private bool collapsed;

    /// <returns>True once when the window reappears.</returns>
    public bool Feed(double t, bool running, bool hidden, bool hasWindow, bool hasVisibleMain)
    {
        if (!running) { since = null; collapsed = false; return false; }
        if (!hidden && !hasWindow)
        {
            since ??= t;
            if (t - since.Value >= CollapseSeconds) collapsed = true;
            return false;
        }
        since = null;
        if (collapsed && hasVisibleMain) { collapsed = false; return true; }
        return false;
    }
}

public enum QuietState { Normal, Fullscreen, Game, Presentation }

public static class QuietRules
{
    /// <summary>Whether to skip because the user is in a full-screen app, game or presentation (COMPATIBILITY.md §3).</summary>
    public static (bool Skip, string? Detail) Skip(bool enabled, QuietState state) => !enabled || state == QuietState.Normal
        ? (false, null)
        : (true, state switch { QuietState.Game => "game", QuietState.Presentation => "presentation", _ => "fullscreen" });
}
