namespace GardenBoot.Core;

public enum SessionChange { None, Started, Ended }

/// <summary>
/// Tracks the target app across process snapshots. ChatGPT on Windows runs as a group of processes, so a cold
/// launch is the step from "no target process" to "some target process", and the session ends when the last one
/// exits. Processes already running when the launcher starts form the baseline and never trigger playback.
/// </summary>
public sealed class TargetSession
{
    private HashSet<int> alive;

    public TargetSession(IEnumerable<int> runningAtStart)
    {
        alive = [.. runningAtStart];
        IsActive = alive.Count > 0;
        IsBaseline = IsActive;
    }

    /// <summary>True while any target process is running.</summary>
    public bool IsActive { get; private set; }
    /// <summary>True while the running group predates the launcher (no animation for it).</summary>
    public bool IsBaseline { get; private set; }
    public IReadOnlySet<int> Processes => alive;

    /// <summary>Feeds the current set of target process ids; reports a cold start or the end of the session.</summary>
    public SessionChange Update(IEnumerable<int> current)
    {
        var now = new HashSet<int>(current);
        var wasActive = IsActive;
        alive = now;
        IsActive = now.Count > 0;
        if (!wasActive && IsActive)
        {
            IsBaseline = false;
            return SessionChange.Started;
        }
        if (wasActive && !IsActive)
        {
            IsBaseline = false;
            return SessionChange.Ended;
        }
        return SessionChange.None;
    }
}

/// <summary>One top-level window as enumerated from the desktop, front-to-back.</summary>
public readonly record struct TopWindow(nint Handle, int ProcessId, bool Visible, bool Owned, bool ToolWindow, bool Cloaked, Box Bounds);

/// <summary>Chooses the target's main window: the frontmost visible, unowned, non-tool, uncloaked window that is big enough.</summary>
public static class WindowChooser
{
    public const double MinimumWidth = 240;
    public const double MinimumHeight = 180;

    public static TopWindow? MainWindow(IEnumerable<TopWindow> frontToBack, IReadOnlySet<int> targetProcesses)
    {
        foreach (var w in frontToBack)
        {
            if (targetProcesses.Contains(w.ProcessId) && w.Visible && !w.Owned && !w.ToolWindow && !w.Cloaked
                && w.Bounds.Width >= MinimumWidth && w.Bounds.Height >= MinimumHeight)
                return w;
        }
        return null;
    }
}
