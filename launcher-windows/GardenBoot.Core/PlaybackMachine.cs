namespace GardenBoot.Core;

public enum EndKind { Completed, Skipped, WindowTimeout, TargetExited, TargetHidden, UserSwitched, Superseded, Failed }

/// <summary>Why a playback ended. Decides whether focus may go back to the target.</summary>
public readonly record struct EndReason(EndKind Kind, string Detail = "")
{
    public bool OffersFocusToTarget => Kind is EndKind.Completed or EndKind.Skipped or EndKind.WindowTimeout or EndKind.Failed;

    public string LogName => Kind switch
    {
        EndKind.Completed => "completed",
        EndKind.Skipped => "skipped",
        EndKind.WindowTimeout => "window-timeout",
        EndKind.TargetExited => "target-exited",
        EndKind.TargetHidden => "target-hidden",
        EndKind.UserSwitched => "user-switched",
        EndKind.Superseded => "superseded",
        _ => $"failed-{Detail}",
    };
}

/// <summary>Inputs the app layer reports to the machine.</summary>
public abstract record PlaybackEvent
{
    /// <summary>A new target launch was detected; <paramref name="WindowAlreadyReady"/> if its window is already visible.</summary>
    public sealed record Start(bool WindowAlreadyReady) : PlaybackEvent;
    public sealed record WindowReady : PlaybackEvent;
    public sealed record SegmentEnded(PackSegment Segment) : PlaybackEvent;
    public sealed record LoopCycleEnded : PlaybackEvent;
    public sealed record ReachedHandoff : PlaybackEvent;
    public sealed record FadeCompleted : PlaybackEvent;
    public sealed record Skip : PlaybackEvent;
    public sealed record WaitTimedOut : PlaybackEvent;
    public sealed record TargetExited : PlaybackEvent;
    public sealed record TargetHidden : PlaybackEvent;
    public sealed record UserSwitched : PlaybackEvent;
    public sealed record Superseded : PlaybackEvent;
    public sealed record Failed(string Why) : PlaybackEvent;
}

/// <summary>Outputs the app layer must carry out, in order.</summary>
public abstract record PlaybackCommand
{
    /// <summary>Show the overlay centred on the screen the launch came from (before the window exists).</summary>
    public sealed record ShowOnLaunchScreen : PlaybackCommand;
    /// <summary>Show the overlay directly on the target window's frame.</summary>
    public sealed record ShowOnTargetWindow : PlaybackCommand;
    public sealed record MoveToTargetWindow(bool Animated) : PlaybackCommand;
    public sealed record Play(PackSegment Segment, bool Looping) : PlaybackCommand;
    public sealed record HoldLastFrame : PlaybackCommand;
    /// <summary>Fade picture and sound to zero over <paramref name="Duration"/> seconds, then report FadeCompleted.</summary>
    public sealed record BeginFade(double Duration) : PlaybackCommand;
    public sealed record Close(EndReason Reason, bool WasVisible) : PlaybackCommand;
}

public enum PlaybackPhase { Idle, WaitingForWindow, Intro, Holding, Looping, Final, Fading, Closed }

/// <summary>
/// Pure state machine for one launch: intro → loop (until the window is ready) → outro → fade. A single-video pack
/// waits invisibly for the window, then plays on it and fades. Events after closing produce no commands.
/// Behaviour is pinned by launcher-spec/conformance/playback.json, shared with the macOS version.
/// </summary>
public sealed class PlaybackMachine(PackLayout layout, double fadeDuration = PackDefaults.FadeDuration, LoopExit loopExit = LoopExit.CycleEnd)
{
    private static readonly IReadOnlyList<PlaybackCommand> None = [];
    private bool visible;
    private bool attached;
    private EndReason fadeReason = new(EndKind.Completed);

    public PlaybackMachine(InstalledPack pack) : this(pack.Layout, pack.Manifest.EffectiveFadeDuration, pack.Manifest.EffectiveLoopExit) { }

    public PlaybackPhase Phase { get; private set; } = PlaybackPhase.Idle;
    public EndReason? ClosedReason { get; private set; }
    public bool WindowIsReady { get; private set; }
    /// <summary>True once the overlay sits on the target window (it then follows the window until the fade).</summary>
    public bool IsOnTargetWindow => attached;
    public bool IsClosed => Phase == PlaybackPhase.Closed;

    public IReadOnlyList<PlaybackCommand> Handle(PlaybackEvent e)
    {
        if (IsClosed) return None;
        switch (e)
        {
            case PlaybackEvent.Start start:
                if (Phase != PlaybackPhase.Idle) return None;
                WindowIsReady = start.WindowAlreadyReady;
                return Begin();
            case PlaybackEvent.WindowReady:
                if (WindowIsReady) return None;
                WindowIsReady = true;
                return WindowBecameReady();
            case PlaybackEvent.SegmentEnded ended:
                return SegmentEnded(ended.Segment);
            case PlaybackEvent.LoopCycleEnded:
                return Phase == PlaybackPhase.Looping && WindowIsReady && loopExit == LoopExit.CycleEnd ? PlayFinal() : None;
            case PlaybackEvent.ReachedHandoff:
                return Phase == PlaybackPhase.Final ? Fade(new(EndKind.Completed), fadeDuration) : None;
            case PlaybackEvent.FadeCompleted:
                return Phase == PlaybackPhase.Fading ? Close(fadeReason) : None;
            case PlaybackEvent.Skip:
                return Phase switch
                {
                    PlaybackPhase.Idle or PlaybackPhase.Fading => None,
                    PlaybackPhase.WaitingForWindow => Close(new(EndKind.Skipped)),
                    _ => Fade(new(EndKind.Skipped), PackDefaults.SkipFadeDuration),
                };
            case PlaybackEvent.WaitTimedOut:
                if (WindowIsReady) return None;
                return Phase switch
                {
                    PlaybackPhase.WaitingForWindow => Close(new(EndKind.WindowTimeout)),
                    PlaybackPhase.Intro or PlaybackPhase.Holding or PlaybackPhase.Looping => Fade(new(EndKind.WindowTimeout), fadeDuration),
                    _ => None,
                };
            case PlaybackEvent.TargetExited: return Close(new(EndKind.TargetExited));
            case PlaybackEvent.TargetHidden: return WindowIsReady ? None : Close(new(EndKind.TargetHidden));
            case PlaybackEvent.UserSwitched: return Close(new(EndKind.UserSwitched));
            case PlaybackEvent.Superseded: return Close(new(EndKind.Superseded));
            case PlaybackEvent.Failed failed: return Close(new(EndKind.Failed, failed.Why));
            default: return None;
        }
    }

    private IReadOnlyList<PlaybackCommand> Begin()
    {
        if (layout.CoversLaunch && !WindowIsReady)
        {
            visible = true;
            if (layout.Intro is not null)
            {
                Phase = PlaybackPhase.Intro;
                return [new PlaybackCommand.ShowOnLaunchScreen(), new PlaybackCommand.Play(PackSegment.Intro, false)];
            }
            Phase = PlaybackPhase.Looping;
            return [new PlaybackCommand.ShowOnLaunchScreen(), new PlaybackCommand.Play(PackSegment.Loop, true)];
        }
        if (WindowIsReady) return ShowFinalOnWindow();
        Phase = PlaybackPhase.WaitingForWindow;
        return None;
    }

    private IReadOnlyList<PlaybackCommand> WindowBecameReady() => Phase switch
    {
        PlaybackPhase.WaitingForWindow => ShowFinalOnWindow(),
        PlaybackPhase.Holding => PlayFinal(),
        PlaybackPhase.Looping when loopExit == LoopExit.Immediate => PlayFinal(),
        // Move onto the window at once; the intro keeps playing there and a cycle-end loop still finishes its cycle.
        PlaybackPhase.Intro or PlaybackPhase.Looping when !attached => Attach(),
        _ => None,
    };

    private IReadOnlyList<PlaybackCommand> Attach()
    {
        attached = true;
        return [new PlaybackCommand.MoveToTargetWindow(true)];
    }

    private IReadOnlyList<PlaybackCommand> SegmentEnded(PackSegment segment)
    {
        if (Phase == PlaybackPhase.Intro && segment == PackSegment.Intro)
        {
            if (WindowIsReady) return PlayFinal();
            if (layout.Loop is not null)
            {
                Phase = PlaybackPhase.Looping;
                return [new PlaybackCommand.Play(PackSegment.Loop, true)];
            }
            Phase = PlaybackPhase.Holding;
            return [new PlaybackCommand.HoldLastFrame()];
        }
        // Reached the end of the final segment without a handoff report: fade anyway.
        return Phase == PlaybackPhase.Final && segment == layout.FinalSegment ? Fade(new(EndKind.Completed), fadeDuration) : None;
    }

    private IReadOnlyList<PlaybackCommand> ShowFinalOnWindow()
    {
        visible = true;
        attached = true;
        Phase = PlaybackPhase.Final;
        return [new PlaybackCommand.ShowOnTargetWindow(), new PlaybackCommand.Play(layout.FinalSegment, false)];
    }

    private IReadOnlyList<PlaybackCommand> PlayFinal()
    {
        Phase = PlaybackPhase.Final;
        var play = new PlaybackCommand.Play(layout.FinalSegment, false);
        if (attached) return [play];
        attached = true;
        return [new PlaybackCommand.MoveToTargetWindow(true), play];
    }

    private IReadOnlyList<PlaybackCommand> Fade(EndReason reason, double duration)
    {
        if (!visible) return Close(reason);
        fadeReason = reason;
        Phase = PlaybackPhase.Fading;
        return [new PlaybackCommand.BeginFade(duration)];
    }

    private IReadOnlyList<PlaybackCommand> Close(EndReason reason)
    {
        var wasVisible = visible;
        Phase = PlaybackPhase.Closed;
        ClosedReason = reason;
        return [new PlaybackCommand.Close(reason, wasVisible)];
    }
}
