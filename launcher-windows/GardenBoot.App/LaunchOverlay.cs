using System.Diagnostics;
using System.Globalization;
using System.Windows.Threading;
using GardenBoot.Core;
using EventLog = GardenBoot.Core.EventLog;

namespace GardenBoot.App;

/// <summary>Desktop adapter for PlaybackMachine; only the core chooses playback transitions.</summary>
internal sealed class LaunchOverlay
{
    private const double PrepareLimit = 6, StallLimit = 6, PreviewDelay = 3, RevealDuration = 0.12;
    private readonly InstalledPack pack;
    private readonly TargetMonitor monitor;
    private readonly TrayIcon tray;
    private readonly EventLog log;
    private readonly bool preview;
    private readonly Action<EndReason> onFinish;
    private readonly PlaybackMachine machine;
    private readonly Queue<PlaybackEvent> inbox = new();
    private readonly Dictionary<PackSegment, MediaClip> clips = new();
    private readonly CancellationTokenSource loading = new();
    private readonly DispatcherTimer timer;
    private readonly Stopwatch age = Stopwatch.StartNew();
    private readonly DesktopFrame launchFrame;
    private DesktopFrame? targetFrame;
    private nint targetWindow;
    private OverlayWindow? window;
    private MediaClip? active;
    private PackSegment? activeSegment;
    private bool draining, windowReported, timeoutReported, handoffReported, escapeRegistered;
    private (PackSegment Segment, bool Looping, double Since)? queued;
    private (Box From, DesktopFrame To, double Start, double Duration)? move;
    private (double Start, double Duration, double Volume)? fade;
    private double? shownAt, stalledSince, revealStart;
    private (string Place, DesktopFrame Frame)? pendingShow;
    private MediaClip? warm;
    private readonly string? targetId;
    private TargetSession Session => monitor.SessionOf(targetId);
    public string? TargetId => targetId;
    /// <summary>Seconds from the start of this playback until the target's main window was found (null if never).</summary>
    public double? WindowReadyAge { get; private set; }
    private bool usedWarm;
    private double lastWindowQuery = -1, lastFollowQuery = -1, lastPosition;
    public double Age => age.Elapsed.TotalSeconds;
    public bool IsPreview => preview;

    public LaunchOverlay(InstalledPack pack, TargetMonitor monitor, TrayIcon tray, EventLog log,
                         bool preview, Action<EndReason> onFinish, double coverage = .72, MediaClip? warmFirst = null, string? targetId = null)
    {
        this.targetId = targetId;
        warm = warmFirst;
        this.pack = pack;
        this.monitor = monitor;
        this.tray = tray;
        this.log = log;
        this.preview = preview;
        this.onFinish = onFinish;
        machine = new PlaybackMachine(pack);
        var work = TargetMonitor.PointerWorkArea();
        launchFrame = new(OverlayGeometry.LaunchFrame(work.Bounds, coverage: coverage), work.Scale);
        timer = new DispatcherTimer(DispatcherPriority.Render) { Interval = TimeSpan.FromSeconds(1.0 / 60) };
        timer.Tick += (_, _) => Tick();
    }

    public void Begin()
    {
        timer.Start();
        if (!preview) RefreshTargetFrame();
        windowReported = targetFrame is not null || (preview && !pack.Layout.CoversLaunch);
        if (targetFrame is not null) WindowReadyAge = 0;
        Send(new PlaybackEvent.Start(windowReported));
        if (!machine.IsClosed) _ = Preload();
    }

    // Media/Win32 callbacks may enqueue events while a command is being performed. Finish every
    // command in that transition before dispatching the next event, including failure and close.
    public void Send(PlaybackEvent evt)
    {
        if (machine.IsClosed) return;
        inbox.Enqueue(evt);
        if (draining) return;
        draining = true;
        try
        {
            while (inbox.TryDequeue(out var next))
                foreach (var command in machine.Handle(next)) Perform(command);
        }
        finally { draining = false; }
    }

    private void Perform(PlaybackCommand command)
    {
        switch (command)
        {
            case PlaybackCommand.ShowOnLaunchScreen: Present(launchFrame, "launch-screen"); break;
            case PlaybackCommand.ShowOnTargetWindow: Present(targetFrame ?? launchFrame, "target-window"); break;
            case PlaybackCommand.MoveToTargetWindow movement:
                if (window is null || targetFrame is not { } target) break;
                log.Write($"player-move animated={movement.Animated} to={Format(target.Bounds)}");
                if (movement.Animated) StartMove(target, 0.45);
                else window.SetFrame(target);
                break;
            case PlaybackCommand.Play play:
                queued = (play.Segment, play.Looping, Age);
                StartQueued();
                break;
            case PlaybackCommand.HoldLastFrame:
                active?.Pause();
                stalledSince = null;
                log.Write("player-hold-last-frame");
                break;
            case PlaybackCommand.BeginFade beginFade:
                move = null;
                // Freeze geometry and let audio and picture keep playing while they fade together.
                fade = (Age, beginFade.Duration, active?.Player.Volume ?? 0);
                log.Write($"player-fade duration={beginFade.Duration.ToString(CultureInfo.InvariantCulture)}");
                break;
            case PlaybackCommand.Close close: Finish(close.Reason, close.WasVisible); break;
        }
    }

    private void Present(DesktopFrame frame, string place)
    {
        window = new OverlayWindow(() => Send(new PlaybackEvent.Skip())) { FitMode = pack.Manifest.EffectiveVideoFit, Log = log.Write };
        window.ShowHidden(frame); // positioned but invisible until the first frame (LAUNCH-LATENCY.md)
        escapeRegistered = tray.SetEscape(() => Send(new PlaybackEvent.Skip()));
        if (!escapeRegistered) log.Write("skip-hotkey-unavailable");
        pendingShow = (place, frame);
        RevealIfReady();
    }

    /// <summary>Fades the overlay in once a video frame is actually on screen.</summary>
    private void RevealIfReady()
    {
        if (pendingShow is not { } show || window is null || active is null || active.Position <= 0) return;
        pendingShow = null;
        revealStart = shownAt = Age;
        log.Write(FormattableString.Invariant($"first-frame age={Age:F3} warm={usedWarm.ToString().ToLowerInvariant()} segment={activeSegment?.ToString().ToLowerInvariant()}"));
        log.Write($"player-show location={show.Place} frame={Format(window.FrameAtScale(show.Frame.Scale))} pack={pack.Id}");
    }

    private async Task Preload()
    {
        try
        {
            foreach (var (segment, file) in pack.Manifest.Segments)
            {
                var path = pack.PathFor(file);
                MediaClip clip;
                if (warm is { } candidate && candidate.Path == path && !usedWarm) { clip = candidate; usedWarm = true; warm = null; }
                else clip = new MediaClip(path, segment == PackSegment.Loop);
                clips.Add(segment, clip);
                clip.Failed += () => Send(new PlaybackEvent.Failed("decode"));
                clip.Ended += () =>
                {
                    if (active == clip) Send(new PlaybackEvent.SegmentEnded(segment));
                };
                clip.CycleEnded += () =>
                {
                    if (active == clip) Send(new PlaybackEvent.LoopCycleEnded());
                };
                // Each segment starts as soon as it alone is ready; the rest keep loading.
                _ = clip.Ready.ContinueWith(_ => StartQueued(), CancellationToken.None, TaskContinuationOptions.OnlyOnRanToCompletion,
                                            TaskScheduler.FromCurrentSynchronizationContext());
            }
            warm?.Dispose(); // a warm clip for a different file is not used
            warm = null;
            StartQueued();
            await Task.WhenAll(clips.Values.Select(c => c.Ready)).WaitAsync(TimeSpan.FromSeconds(PrepareLimit), loading.Token);
            if (machine.IsClosed) return;
            log.Write($"media-preloaded segments={clips.Count}");
            StartQueued();
        }
        catch (OperationCanceledException) { }
        catch (TimeoutException) { Send(new PlaybackEvent.Failed("prepare-timeout")); }
        catch (Exception e)
        {
            log.Write($"media-preload-failed type={e.GetType().Name}");
            Send(new PlaybackEvent.Failed("media"));
        }
    }

    private void StartQueued()
    {
        if (queued is not { } request || machine.IsClosed || fade is not null) return;
        if (!clips.TryGetValue(request.Segment, out var next) || !next.Ready.IsCompletedSuccessfully) return; // keep the current picture
        queued = null;
        active?.Pause();
        if (active is not null) active.Player.Volume = 0;
        active = clips[request.Segment];
        activeSegment = request.Segment;
        handoffReported = false;
        stalledSince = null;
        lastPosition = 0;
        window?.SetImage(active.Image);
        active.Play(pack.Manifest.EffectiveVolume);
        log.Write($"player-play segment={request.Segment.ToString().ToLowerInvariant()} loop={request.Looping}");
    }

    private void Tick()
    {
        if (machine.IsClosed) return;
        var now = Age;
        if (!preview && !Session.IsActive) { Send(new PlaybackEvent.TargetExited()); return; }
        if (fade is { } fading)
        {
            var progress = (now - fading.Start) / fading.Duration;
            var remaining = 1 - OverlayGeometry.Ease(progress);
            if (window is not null) window.SetAlpha(Math.Min(window.Alpha, remaining));
            if (active is not null) active.Player.Volume = fading.Volume * remaining;
            if (progress >= 1)
            {
                fade = null;
                log.Write("fade-completed");
                Send(new PlaybackEvent.FadeCompleted());
            }
            return;
        }
        RevealIfReady();
        if (revealStart is { } revealed && window is not null)
        {
            var progress = (now - revealed) / RevealDuration;
            window.SetAlpha(OverlayGeometry.Ease(progress));
            if (progress >= 1) revealStart = null;
        }
        if (move is { } moving && window is not null)
        {
            var progress = (now - moving.Start) / moving.Duration;
            window.SetFrame(new(OverlayGeometry.Interpolate(moving.From, moving.To.Bounds, progress), moving.To.Scale));
            if (progress >= 1) move = null;
        }
        if (shownAt is { } shown)
            window?.SetHint(0.85 * OverlayGeometry.Ease((now - shown - 0.8) / 0.4), escapeRegistered);
        PollWindow(now);
        if (machine.IsClosed || fade is not null) return;
        FollowWindow(now);
        if (!windowReported && !timeoutReported && now >= pack.Manifest.EffectiveMaxWait)
        {
            timeoutReported = true;
            log.Write("wait-timed-out");
            Send(new PlaybackEvent.WaitTimedOut());
        }
        if (machine.IsClosed || fade is not null) return;
        if (queued is { } request && now - request.Since > PrepareLimit)
        { Send(new PlaybackEvent.Failed("prepare-timeout")); return; }
        if (active is { } playing)
        {
            playing.Poll(); // loop boundary may change the active clip through the state machine
            if (machine.IsClosed || fade is not null) return;
            if (active is { } final && machine.Phase == PlaybackPhase.Final && activeSegment == pack.Layout.FinalSegment
                && !handoffReported && final.Position >= pack.Manifest.HandoffTime(final.Duration))
            {
                handoffReported = true;
                log.Write("player-handoff");
                Send(new PlaybackEvent.ReachedHandoff());
            }
            if (fade is null) WatchStall(now);
        }
    }

    private void PollWindow(double now)
    {
        if (windowReported || now - lastWindowQuery < 0.15) return;
        lastWindowQuery = now;
        if (!preview)
        {
            RefreshTargetFrame();
            if (targetFrame is null && TargetMonitor.IsHidden(Session.Processes))
            { Send(new PlaybackEvent.TargetHidden()); return; }
        }
        if (targetFrame is null && !(preview && now >= PreviewDelay)) return;
        windowReported = true;
        if (targetFrame is not null) WindowReadyAge ??= now;
        log.Write($"window-ready preview={preview}");
        Send(new PlaybackEvent.WindowReady());
    }

    private void RefreshTargetFrame()
    {
        if (TargetMonitor.MainWindow(Session.Processes) is { } main)
        { targetFrame = main.Frame; targetWindow = main.Window.Handle; }
    }

    private void FollowWindow(double now)
    {
        if (preview || !windowReported || !machine.IsOnTargetWindow || machine.Phase is PlaybackPhase.Fading or PlaybackPhase.Closed
            || window is null || now - lastFollowQuery < 0.15) return;
        lastFollowQuery = now;
        if (TargetMonitor.MainWindow(Session.Processes) is not { } main) return;
        var latest = main.Frame;
        var current = move is { } moving ? moving.To.AtScale(latest.Scale) : window.FrameAtScale(latest.Scale);
        if (!OverlayGeometry.ShouldFollow(current, latest.Bounds)) return;
        targetFrame = latest;
        targetWindow = main.Window.Handle;
        log.Write($"player-follow to={Format(latest.Bounds)}");
        StartMove(latest, 0.22);
    }

    private void StartMove(DesktopFrame destination, double duration)
    {
        if (window is not null)
            move = (window.FrameAtScale(destination.Scale), destination, Age, duration);
    }

    private void WatchStall(double now)
    {
        if (active is null || machine.Phase is not (PlaybackPhase.Intro or PlaybackPhase.Looping or PlaybackPhase.Final))
        { stalledSince = null; return; }
        var position = active.Position;
        if (active.Player.IsBuffering || Math.Abs(position - lastPosition) < 0.001)
        {
            stalledSince ??= now;
            if (now - stalledSince > StallLimit) Send(new PlaybackEvent.Failed("stalled"));
        }
        else stalledSince = null;
        lastPosition = position;
    }

    private void Finish(EndReason reason, bool wasVisible)
    {
        timer.Stop();
        tray.SetEscape(null);
        loading.Cancel();
        loading.Dispose();
        foreach (var clip in clips.Values) clip.Dispose();
        warm?.Dispose();
        warm = null;
        clips.Clear();
        active = null;
        window?.Close();
        window = null;
        move = null;
        fade = null;
        Native.GetWindowThreadProcessId(Native.GetForegroundWindow(), out var foreground);
        if (!preview && reason.OffersFocusToTarget && foreground == Environment.ProcessId && targetWindow != 0
            && PlaybackPolicy.ShouldReturnFocus((int)foreground, Environment.ProcessId, Session.Processes, Session.IsActive))
            Native.SetForegroundWindow(targetWindow);
        log.Write($"player-finished reason={reason.LogName} wasVisible={wasVisible}");
        onFinish(reason);
    }

    private static string Format(Box box) => FormattableString.Invariant($"{box.X:F0},{box.Y:F0},{box.Width:F0},{box.Height:F0}");
}
