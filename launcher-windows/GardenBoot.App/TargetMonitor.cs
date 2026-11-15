using System.Diagnostics;
using System.IO;
using System.Runtime.InteropServices;
using System.Text;
using System.Text.RegularExpressions;
using System.Windows.Threading;
using GardenBoot.Core;

namespace GardenBoot.App;

/// <summary>All desktop rectangles enter the core in DIPs; the scale travels with each frame.</summary>
internal readonly record struct DesktopFrame(Box Bounds, double Scale)
{
    public Box AtScale(double scale) => new(Bounds.X * Scale / scale, Bounds.Y * Scale / scale,
                                            Bounds.Width * Scale / scale, Bounds.Height * Scale / scale);
}

/// <summary>One watched target: identity and whether a reappearing window also counts (COMPATIBILITY.md §2).</summary>
internal sealed record WatchedTarget(string Id, WindowsTargetIdentity Identity, bool Reappear);

/// <summary>Watches every enabled target app (launcher-spec/TARGETS.md), one process-group session per target.</summary>
internal sealed class TargetMonitor : IDisposable
{
    private static readonly TargetSession Empty = new([]);
    private readonly Dispatcher dispatcher;
    private readonly DispatcherTimer timer;
    private readonly Native.WinEventProc foregroundCallback;
    private IReadOnlyList<WatchedTarget> targets = [];
    private readonly Dictionary<string, (ReappearTracker Tracker, bool SeenWindow)> reappear = new(StringComparer.Ordinal);
    private readonly System.Diagnostics.Stopwatch clock = System.Diagnostics.Stopwatch.StartNew();
    /// <summary>Raised when a running target brings a window back after having none (opt-in per target).</summary>
    public event Action<string>? Reappeared;
    private readonly Dictionary<string, (string Key, TargetSession Session)> sessions = new(StringComparer.Ordinal);
    private nint foregroundHook;
    private bool disposed;
    /// <summary>Raised per target: a cold start or the end of its session.</summary>
    public event Action<string, SessionChange>? Changed;
    public event Action<int>? ForegroundChanged;
    /// <summary>Raised when two polls were more than a second apart (diagnostics: samples were missed).</summary>
    public event Action<double>? Stalled;
    private double lastPoll = -1;
    public IReadOnlyCollection<string> TargetIds => sessions.Keys;

    public TargetMonitor(IReadOnlyList<WatchedTarget> watched)
    {
        dispatcher = Dispatcher.CurrentDispatcher;
        Configure(watched);
        // Normal, not Background: after a playback the warm-up work could starve a Background timer for seconds, and a
        // window hidden and shown again inside that gap was never seen gone (intermittent reappear miss, P-011).
        // A tick costs well under a millisecond since P-012, so this does not disturb playback.
        timer = new DispatcherTimer(DispatcherPriority.Normal) { Interval = TimeSpan.FromMilliseconds(250) };
        timer.Tick += (_, _) => Poll();
        foregroundCallback = (_, _, window, _, _, _, _) =>
        {
            if (window == 0 || disposed) return;
            Native.GetWindowThreadProcessId(window, out var pid);
            if (pid == 0) return;
            dispatcher.BeginInvoke(new Action(() => { if (!disposed) ForegroundChanged?.Invoke((int)pid); }));
        };
    }

    /// <summary>
    /// Replaces the watched set. A target that keeps its identity keeps its session; a new one starts from the processes
    /// running now as its baseline, so changing settings never plays for apps that are already open.
    /// </summary>
    public void Configure(IReadOnlyList<WatchedTarget> watched)
    {
        targets = watched;
        var snapshot = Snapshot();
        var next = new Dictionary<string, (string, TargetSession)>(StringComparer.Ordinal);
        foreach (var t in watched)
            if (t.Reappear && !reappear.ContainsKey(t.Id)) reappear[t.Id] = (new ReappearTracker(), true);
        foreach (var id in reappear.Keys.Where(id => !watched.Any(t => t.Id == id && t.Reappear)).ToList()) reappear.Remove(id);
        foreach (var (id, identity, _) in watched)
        {
            var key = TargetRules.WindowsKey(identity);
            next[id] = sessions.TryGetValue(id, out var old) && old.Key == key ? old : (key, new TargetSession(snapshot.GetValueOrDefault(id) ?? []));
        }
        sessions.Clear();
        foreach (var (id, value) in next) sessions[id] = value;
    }

    public TargetSession SessionOf(string? id) => id is not null && sessions.TryGetValue(id, out var s) ? s.Session : Empty;

    public bool Start()
    {
        foregroundHook = Native.SetWinEventHook(3, 3, 0, foregroundCallback, 0, 0, 0); // EVENT_SYSTEM_FOREGROUND, OUTOFCONTEXT
        timer.Start();
        return foregroundHook != 0;
    }

    private void Poll()
    {
        var tick = clock.Elapsed.TotalSeconds;
        if (lastPoll >= 0 && tick - lastPoll > 1) Stalled?.Invoke(tick - lastPoll);
        lastPoll = tick;
        var snapshot = Snapshot();
        foreach (var (id, (_, session)) in sessions.ToList())
        {
            var change = session.Update(snapshot.GetValueOrDefault(id) ?? []);
            // A cold start is reported as such; its first window must not also count as "reappeared".
            if (change == SessionChange.Started && reappear.TryGetValue(id, out var r)) reappear[id] = (r.Tracker, false);
            if (change != SessionChange.None) Changed?.Invoke(id, change);
        }
        var now = clock.Elapsed.TotalSeconds;
        foreach (var (id, (tracker, seen)) in reappear.ToList())
        {
            var session = SessionOf(id);
            if (!session.IsActive) { tracker.Feed(now, false, false, false, false); continue; }
            var windows = Windows(session.Processes);
            var visibleMain = MainWindow(session.Processes) is not null;
            // A minimized window reports a tiny caption-sized frame, so it counts regardless of size (restore ≠ reappear).
            var hasWindow = windows.Any(w => !w.Owned && !w.ToolWindow && (Native.IsIconic(w.Handle)
                || (Native.IsWindowVisible(w.Handle) && !w.Cloaked && w.Bounds.Width >= WindowChooser.MinimumWidth && w.Bounds.Height >= WindowChooser.MinimumHeight)));
            if (!seen) { if (visibleMain) reappear[id] = (tracker, true); tracker.Feed(now, true, false, true, false); continue; }
            if (tracker.Feed(now, true, false, hasWindow, visibleMain)) Reappeared?.Invoke(id);
        }
    }

    private static readonly char[] PathBuffer = new char[1024];

    private static string? ImagePath(int pid)
    {
        var handle = Native.OpenProcess(0x1000, false, (uint)pid); // QUERY_LIMITED_INFORMATION
        if (handle == 0) return null; // protected/exited processes are normal
        try
        {
            uint size = (uint)PathBuffer.Length;
            if (Native.QueryFullProcessImageName(handle, 0, PathBuffer, ref size)) return new string(PathBuffer, 0, (int)size);
            var path = new StringBuilder(32768); // rare: a path longer than 1024 characters
            size = (uint)path.Capacity;
            return Native.QueryFullProcessImageName(handle, 0, path, ref size) ? path.ToString() : null;
        }
        finally { Native.CloseHandle(handle); }
    }

    // P-012 (idle cost): a pid's image path is asked once, while that pid stays in the list. Asking every process every
    // 250 ms cost about 7% of one core on a 330-process machine. A pid that leaves the list is forgotten; reuse of the
    // same pid between two snapshots 250 ms apart would need the old process fully released and a new one created in
    // that gap, which Windows' pid allocation makes very unlikely.
    private readonly Dictionary<uint, string?> paths = [];
    private uint[] pidBuffer = new uint[1024];

    private uint[] CurrentPids(out int count)
    {
        while (true)
        {
            if (!Native.EnumProcesses(pidBuffer, (uint)(pidBuffer.Length * sizeof(uint)), out var bytes)) { count = 0; return pidBuffer; }
            count = (int)(bytes / sizeof(uint));
            if (count < pidBuffer.Length) return pidBuffer;
            pidBuffer = new uint[pidBuffer.Length * 2]; // full buffer: the list may be truncated
        }
    }

    /// <summary>Target id → its running process ids, from one pass over all processes.</summary>
    private Dictionary<string, HashSet<int>> Snapshot()
    {
        var result = new Dictionary<string, HashSet<int>>(StringComparer.Ordinal);
        if (targets.Count == 0) { paths.Clear(); return result; }
        var pids = CurrentPids(out var count);
        var alive = new HashSet<uint>(count);
        for (var i = 0; i < count; i++)
        {
            var pid = pids[i];
            if (pid == 0) continue;
            alive.Add(pid);
            if (!paths.TryGetValue(pid, out var path)) paths[pid] = path = ImagePath((int)pid);
            if (path is null) continue;
            foreach (var (id, identity, _) in targets)
                if (TargetRules.MatchesWindows(identity, path)) (result.TryGetValue(id, out var set) ? set : result[id] = []).Add((int)pid);
        }
        if (paths.Count > alive.Count) foreach (var gone in paths.Keys.Where(p => !alive.Contains(p)).ToList()) paths.Remove(gone);
        return result;
    }

    // Foreground events can arrive just before the next 250-ms process snapshot. Recognize a
    // newly created target child by path too, rather than ending playback because its PID is new.
    public bool IsTargetProcess(string? id, int pid)
    {
        if (id is null) return false;
        if (SessionOf(id).Processes.Contains(pid)) return true;
        var identity = targets.FirstOrDefault(t => t.Id == id)?.Identity;
        return identity is not null && ImagePath(pid) is { } path && TargetRules.MatchesWindows(identity, path);
    }

    public static IReadOnlyList<TopWindow> Windows(IReadOnlySet<int> pids)
    {
        var windows = new List<TopWindow>();
        // EnumWindows enumerates top-level windows in Z order, front to back.
        Native.EnumWindows((window, _) =>
        {
            Native.GetWindowThreadProcessId(window, out var pid);
            if (!pids.Contains((int)pid)) return true;
            var rect = new Native.Rect();
            if (Native.DwmGetWindowAttribute(window, 9, out rect, Marshal.SizeOf<Native.Rect>()) != 0)
                Native.GetWindowRect(window, out rect);
            Native.DwmGetWindowAttribute(window, 14, out int cloaked, sizeof(int));
            var scale = ScaleForWindow(window);
            windows.Add(new(window, (int)pid, Native.IsWindowVisible(window) && !Native.IsIconic(window),
                Native.GetWindow(window, 4) != 0, (Native.GetExStyle(window) & Native.WsExToolWindow) != 0,
                cloaked != 0, ToBox(rect, scale)));
            return true;
        }, 0);
        return windows;
    }

    public static (TopWindow Window, DesktopFrame Frame)? MainWindow(IReadOnlySet<int> pids)
    {
        var window = WindowChooser.MainWindow(Windows(pids), pids);
        return window is { } w ? (w, new DesktopFrame(w.Bounds, ScaleForWindow(w.Handle))) : null;
    }

    // A process without a window is still loading, not hidden. A minimized/cloaked main-sized
    // unowned window is positive evidence for hidden startup before WindowReady was reported.
    // A newly created, not-yet-shown HWND alone is not evidence: normal apps do that while loading.
    public static bool IsHidden(IReadOnlySet<int> pids) => Windows(pids).Any(w => !w.Owned && !w.ToolWindow
        && w.Bounds.Width >= WindowChooser.MinimumWidth && w.Bounds.Height >= WindowChooser.MinimumHeight
        && (Native.IsIconic(w.Handle) || w.Cloaked)) && MainWindow(pids) is null;

    public static DesktopFrame PointerWorkArea()
    {
        Native.GetCursorPos(out var pointer);
        var monitor = Native.MonitorFromPoint(pointer, 2);
        var info = new Native.MonitorInfo { Size = Marshal.SizeOf<Native.MonitorInfo>() };
        if (!Native.GetMonitorInfo(monitor, ref info)) throw new IOException("无法读取显示器工作区");
        var scale = Native.GetDpiForMonitor(monitor, 0, out var dpi, out _) == 0 && dpi > 0 ? dpi / 96.0 : 1;
        return new(ToBox(info.Work, scale), scale);
    }

    public static bool ReduceMotion => Native.SystemParametersInfo(0x1042, 0, out var animate, 0) && !animate;
    internal static double ScaleForWindow(nint window) => Native.GetDpiForWindow(window) is var dpi && dpi > 0 ? dpi / 96.0 : 1;
    internal static Box ToBox(Native.Rect rect, double scale) => new(rect.Left / scale, rect.Top / scale,
        (rect.Right - rect.Left) / scale, (rect.Bottom - rect.Top) / scale);

    public void Dispose()
    {
        disposed = true;
        timer.Stop();
        if (foregroundHook != 0) Native.UnhookWinEvent(foregroundHook);
        foregroundHook = 0;
    }
}
