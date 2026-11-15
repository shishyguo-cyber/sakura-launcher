using System.Windows;
using System.Windows.Media;
using System.Windows.Media.Animation;
using System.Windows.Threading;
using GardenBoot.Core;

namespace GardenBoot.App;

/// <summary>
/// One independent, prerollable Windows media pipeline. Repeating MediaClocks let WPF schedule loop
/// boundaries in its media timing engine rather than seeking/reopening a file in a dispatcher timer.
/// </summary>
internal sealed class MediaClip : IDisposable
{
    private readonly TaskCompletionSource ready = new(TaskCreationOptions.RunContinuationsAsynchronously);
    private readonly MediaClock clock;
    private readonly bool looping;
    private int iteration = 1;
    private bool disposed;
    public MediaPlayer Player { get; } = new() { Volume = 0, ScrubbingEnabled = true };
    public string Path { get; }
    public DrawingImage Image { get; }
    public Task Ready => ready.Task;
    public double Duration { get; private set; }
    public double Position => clock.CurrentTime?.TotalSeconds ?? 0;
    public event Action? Ended;
    public event Action? CycleEnded;
    public event Action? Failed;

    public MediaClip(string path, bool looping)
    {
        Path = path;
        this.looping = looping;
        var drawing = new VideoDrawing { Player = Player, Rect = new Rect(0, 0, 16, 9) };
        Image = new DrawingImage(drawing);
        Player.MediaOpened += (_, _) =>
        {
            if (disposed) return;
            if (!Player.HasVideo || Player.NaturalVideoWidth <= 0 || !Player.NaturalDuration.HasTimeSpan
                || !double.IsFinite(Player.NaturalDuration.TimeSpan.TotalSeconds) || Player.NaturalDuration.TimeSpan.TotalSeconds <= 0)
            {
                ready.TrySetException(new InvalidOperationException("媒体没有可解码的视频画面或有效时长"));
                return;
            }
            Duration = Player.NaturalDuration.TimeSpan.TotalSeconds;
            drawing.Rect = new Rect(0, 0, Player.NaturalVideoWidth, Player.NaturalVideoHeight);
            ready.TrySetResult();
        };
        Player.MediaFailed += (_, e) =>
        {
            if (disposed) return;
            ready.TrySetException(e.ErrorException);
            Failed?.Invoke();
        };
        var timeline = new MediaTimeline(new Uri(path, UriKind.Absolute))
        {
            RepeatBehavior = looping ? RepeatBehavior.Forever : new RepeatBehavior(1),
            FillBehavior = FillBehavior.HoldEnd,
        };
        clock = (MediaClock)timeline.CreateClock(true);
        if (!looping) clock.Completed += (_, _) => RaiseEnded();
        Player.Clock = clock;
        clock.Controller!.Begin();
        clock.Controller.Pause(); // open/resolve/preroll without audible or visible playback
    }

    private bool endedRaised;
    private long? atEndSince;

    /// <summary>Ended fires once per play, from the media clock or from the end-of-media watchdog below.</summary>
    private void RaiseEnded()
    {
        if (disposed || endedRaised) return;
        endedRaised = true;
        Ended?.Invoke();
    }

    public void Play(double volume)
    {
        iteration = 1;
        endedRaised = false; atEndSince = null;
        Player.Volume = volume;
        clock.Controller!.Begin();
        clock.Controller.Resume();
    }

    public void Pause() => clock.Controller!.Pause();

    public void Poll()
    {
        if (disposed) return;
        if (!looping)
        {
            // Watchdog: the media clock occasionally never reports Completed (seen once in desktop runs: the intro
            // stayed on its last frame until the wait limit). Treat 0.3 s parked at the end as the end.
            if (endedRaised || Duration <= 0 || Position < Duration - 0.05) { atEndSince = null; return; }
            atEndSince ??= Environment.TickCount64;
            if (Environment.TickCount64 - atEndSince.Value >= 300) RaiseEnded();
            return;
        }
        var latest = clock.CurrentIteration ?? 1;
        if (latest <= iteration) return;
        // Normally one iteration. Preserve every cycle event after a delayed dispatcher tick.
        var count = latest - iteration;
        iteration = latest;
        for (int i = 0; i < count && !disposed; i++) CycleEnded?.Invoke();
    }

    public void Dispose()
    {
        if (disposed) return;
        disposed = true;
        ready.TrySetCanceled();
        clock.Controller?.Remove();
        Player.Clock = null;
        Player.Close();
    }
}

internal sealed class WindowsMediaProbe(Dispatcher dispatcher)
{
    // PackLibrary deliberately uses ConfigureAwait(false); every WPF decoder must still be created,
    // read and closed on its STA dispatcher, including the second and subsequent probe calls.
    public Task<MediaInfo> Probe(string path, CancellationToken cancellation = default) => dispatcher.InvokeAsync(async () =>
    {
        using var clip = new MediaClip(path, false);
        await clip.Ready.WaitAsync(TimeSpan.FromSeconds(6), cancellation);
        // Preroll a muted frame as well as checking stream metadata.
        clip.Play(0);
        var deadline = Environment.TickCount64 + 6000;
        while (clip.Position <= 0 || clip.Player.IsBuffering)
        {
            if (Environment.TickCount64 >= deadline) throw new TimeoutException("媒体准备超时");
            await Task.Delay(20, cancellation);
        }
        clip.Pause();
        return new MediaInfo(clip.Duration, clip.Player.HasVideo && clip.Player.NaturalVideoWidth > 0);
    }).Task.Unwrap();
}
