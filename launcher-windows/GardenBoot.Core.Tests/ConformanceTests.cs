using System.Globalization;
using System.Text.Json;

namespace GardenBoot.Core.Tests;

/// <summary>Runs launcher-spec/conformance — the same files the macOS tests run.</summary>
public static class ConformanceTests
{
    private static string SpecDirectory()
    {
        for (var dir = new DirectoryInfo(AppContext.BaseDirectory); dir is not null; dir = dir.Parent)
        {
            var candidate = Path.Combine(dir.FullName, "launcher-spec", "conformance");
            if (Directory.Exists(candidate)) return candidate;
        }
        throw new CheckFailed("launcher-spec/conformance not found above " + AppContext.BaseDirectory);
    }

    private static JsonElement Load(string name) =>
        JsonDocument.Parse(File.ReadAllText(Path.Combine(SpecDirectory(), name))).RootElement;

    private static PackSegment Segment(string s) => s switch
    {
        "intro" => PackSegment.Intro, "loop" => PackSegment.Loop, "outro" => PackSegment.Outro, "video" => PackSegment.Video,
        _ => throw new CheckFailed("unknown segment " + s),
    };

    private static string Lower(PackSegment s) => s.ToString().ToLowerInvariant();

    private static PackLayout Layout(JsonElement raw) => new(
        raw.TryGetProperty("intro", out var i) ? i.GetString() : null,
        raw.TryGetProperty("loop", out var l) ? l.GetString() : null,
        raw.GetProperty("final").GetString()!,
        Segment(raw.GetProperty("finalSegment").GetString()!));

    private static PlaybackEvent Event(JsonElement raw) => raw.GetProperty("event").GetString() switch
    {
        "start" => new PlaybackEvent.Start(raw.GetProperty("windowReady").GetBoolean()),
        "windowReady" => new PlaybackEvent.WindowReady(),
        "segmentEnded" => new PlaybackEvent.SegmentEnded(Segment(raw.GetProperty("segment").GetString()!)),
        "loopCycleEnded" => new PlaybackEvent.LoopCycleEnded(),
        "reachedHandoff" => new PlaybackEvent.ReachedHandoff(),
        "fadeCompleted" => new PlaybackEvent.FadeCompleted(),
        "skip" => new PlaybackEvent.Skip(),
        "waitTimedOut" => new PlaybackEvent.WaitTimedOut(),
        "targetExited" => new PlaybackEvent.TargetExited(),
        "targetHidden" => new PlaybackEvent.TargetHidden(),
        "userSwitched" => new PlaybackEvent.UserSwitched(),
        "superseded" => new PlaybackEvent.Superseded(),
        "failed" => new PlaybackEvent.Failed(raw.GetProperty("why").GetString()!),
        var other => throw new CheckFailed("unknown event " + other),
    };

    private static string Fmt(double d) => d.ToString("0.00", CultureInfo.InvariantCulture);

    /// <summary>Same canonical text as the Swift conformance test.</summary>
    private static string Describe(PlaybackCommand c) => c switch
    {
        PlaybackCommand.ShowOnLaunchScreen => "showOnLaunchScreen",
        PlaybackCommand.ShowOnTargetWindow => "showOnTargetWindow",
        PlaybackCommand.MoveToTargetWindow m => $"moveToTargetWindow animated={m.Animated.ToString().ToLowerInvariant()}",
        PlaybackCommand.Play p => $"play {Lower(p.Segment)} looping={p.Looping.ToString().ToLowerInvariant()}",
        PlaybackCommand.HoldLastFrame => "holdLastFrame",
        PlaybackCommand.BeginFade f => $"beginFade {Fmt(f.Duration)}",
        PlaybackCommand.Close x => $"close {x.Reason.LogName} visible={x.WasVisible.ToString().ToLowerInvariant()}",
        _ => "?",
    };

    private static string Describe(JsonElement raw) => raw.GetProperty("command").GetString() switch
    {
        "moveToTargetWindow" => $"moveToTargetWindow animated={raw.GetProperty("animated").GetBoolean().ToString().ToLowerInvariant()}",
        "play" => $"play {raw.GetProperty("segment").GetString()} looping={raw.GetProperty("looping").GetBoolean().ToString().ToLowerInvariant()}",
        "beginFade" => $"beginFade {Fmt(raw.GetProperty("duration").GetDouble())}",
        "close" => $"close {raw.GetProperty("reason").GetString()} visible={raw.GetProperty("wasVisible").GetBoolean().ToString().ToLowerInvariant()}",
        var simple => simple!,
    };

    private static Box Rect(JsonElement raw)
    {
        var n = raw.EnumerateArray().Select(e => e.GetDouble()).ToArray();
        return new Box(n[0], n[1], n[2], n[3]);
    }

    [Test]
    public static void Playback()
    {
        var spec = Load("playback.json");
        var fade = spec.GetProperty("fadeDuration").GetDouble();
        var count = 0;
        foreach (var c in spec.GetProperty("cases").EnumerateArray())
        {
            count++;
            var name = c.GetProperty("name").GetString();
            var exit = c.TryGetProperty("loopExit", out var le) && le.GetString() == "immediate" ? LoopExit.Immediate : LoopExit.CycleEnd;
            var machine = new PlaybackMachine(Layout(c.GetProperty("layout")), fade, exit);
            var index = 0;
            foreach (var step in c.GetProperty("steps").EnumerateArray())
            {
                var got = machine.Handle(Event(step.GetProperty("event"))).Select(Describe);
                var want = step.GetProperty("expect").EnumerateArray().Select(Describe);
                Check.Sequence(want, got, $"{name} step {index++}");
            }
        }
        Check.True(count > 0, "has cases");
    }

    [Test]
    public static void Manifest()
    {
        var spec = Load("manifest.json");
        foreach (var c in spec.GetProperty("manifests").EnumerateArray())
        {
            var name = c.GetProperty("name").GetString()!;
            var json = c.GetProperty("json").GetRawText();
            if (c.GetProperty("valid").GetBoolean())
            {
                var layout = PackManifest.Parse(json).ValidatedLayout();
                var want = c.GetProperty("layout");
                Check.Equal(Layout(want), layout, name);
                Check.Equal(want.GetProperty("coversLaunch").GetBoolean(), layout.CoversLaunch, name);
                if (c.TryGetProperty("expectVideoFit", out var fit))
                    Check.Equal(fit.GetString(), PackManifest.Parse(json).VideoFit?.LogName(), name);
                if (c.TryGetProperty("expectCover", out var cover))
                    Check.Equal(cover.ValueKind == JsonValueKind.Null ? null : cover.GetString(), PackManifest.Parse(json).Cover, name);
            }
            else
            {
                Check.Throws<PackException>(() => PackManifest.Parse(json).ValidatedLayout(), name);
            }
        }
        foreach (var c in spec.GetProperty("handoff").EnumerateArray())
        {
            var manifest = new PackManifest(1, "a", "A", new Dictionary<PackSegment, string> { [PackSegment.Video] = "v.mp4" },
                HandoffAt: c.TryGetProperty("handoffAt", out var h) ? h.GetDouble() : null,
                FadeDuration: c.TryGetProperty("fadeDuration", out var f) ? f.GetDouble() : null);
            Check.Near(c.GetProperty("expect").GetDouble(), manifest.HandoffTime(c.GetProperty("finalDuration").GetDouble()), what: c.GetRawText());
        }
    }

    [Test]
    public static void Geometry()
    {
        var spec = Load("geometry.json");
        foreach (var c in spec.GetProperty("launchFrame").EnumerateArray())
            Check.Equal(Rect(c.GetProperty("expect")), OverlayGeometry.LaunchFrame(Rect(c.GetProperty("visible")), c.GetProperty("aspect").GetDouble()), c.GetRawText());
        foreach (var c in spec.GetProperty("follow").EnumerateArray())
            Check.Equal(c.GetProperty("expect").GetBoolean(), OverlayGeometry.ShouldFollow(Rect(c.GetProperty("current")), Rect(c.GetProperty("latest"))), c.GetRawText());
        foreach (var c in spec.GetProperty("videoFit").EnumerateArray())
        {
            var name = c.GetProperty("name").GetString()!;
            var frame = c.GetProperty("frame").EnumerateArray().Select(e => e.GetDouble()).ToArray();
            var mode = VideoFitNames.Parse(c.GetProperty("mode").GetString()!);
            var (applied, content) = VideoFit.Resolve(mode, frame[0], frame[1], c.GetProperty("videoAspect").GetDouble());
            Check.Equal(c.GetProperty("expect").GetString(), applied.LogName(), name);
            var want = c.GetProperty("content").EnumerateArray().Select(e => e.GetDouble()).ToArray();
            Check.Near(want[0], content.X, 1e-6, name); Check.Near(want[1], content.Y, 1e-6, name);
            Check.Near(want[2], content.Width, 1e-6, name); Check.Near(want[3], content.Height, 1e-6, name);
        }
        foreach (var pair in spec.GetProperty("ease").EnumerateArray())
        {
            var p = pair.EnumerateArray().Select(e => e.GetDouble()).ToArray();
            Check.Near(p[1], OverlayGeometry.Ease(p[0]));
        }
    }

    [Test]
    public static void Policy()
    {
        var spec = Load("policy.json");
        foreach (var c in spec.GetProperty("launchFilter").EnumerateArray())
        {
            var got = LaunchFilter.Skip(c.GetProperty("targetHidden").GetBoolean(), c.GetProperty("launcherAge").GetDouble(),
                                        c.GetProperty("startedAtLogin").GetBoolean(), c.GetProperty("uptime").GetDouble());
            var want = c.GetProperty("expect").ValueKind == JsonValueKind.Null ? null : c.GetProperty("expect").GetString();
            Check.Equal(want, got?.LogName(), c.GetRawText());
        }
        foreach (var c in spec.GetProperty("activation").EnumerateArray())
            Check.Equal(c.GetProperty("expect").GetBoolean(),
                        PlaybackPolicy.EndsOnActivation(c.GetProperty("isLauncher").GetBoolean(), c.GetProperty("isTarget").GetBoolean(),
                                                        c.GetProperty("age").GetDouble()), c.GetRawText());
        foreach (var c in spec.GetProperty("autoPlay").EnumerateArray())
            Check.Equal(c.GetProperty("expect").GetBoolean(),
                        PlaybackPolicy.ShouldAutoPlay(c.GetProperty("paused").GetBoolean(), c.GetProperty("reduceMotion").GetBoolean(),
                                                      c.GetProperty("override").GetBoolean()), c.GetRawText());
    }

    private static double? OptionalDouble(JsonElement o, string key) =>
        o.TryGetProperty(key, out var v) && v.ValueKind != JsonValueKind.Null ? v.GetDouble() : null;

    private static string? OptionalText(JsonElement o, string key) =>
        o.TryGetProperty(key, out var v) && v.ValueKind != JsonValueKind.Null ? v.GetString() : null;

    [Test]
    public static void Schedule()
    {
        var spec = Load("schedule.json");
        var count = 0;
        foreach (var c in spec.GetProperty("decide").EnumerateArray())
        {
            count++;
            var st = c.GetProperty("state");
            var state = new PlaybackState { LastAutoPlayAt = OptionalDouble(st, "lastAutoPlayAt"), SnoozeUntil = OptionalDouble(st, "snoozeUntil") };
            var frequency = c.GetProperty("frequency").GetString() == "firstOfDay" ? PlayFrequency.FirstOfDay : PlayFrequency.EveryLaunch;
            var got = ScheduleDecision.Decide(frequency, c.GetProperty("dayStartHour").GetInt32(), state, c.GetProperty("now").GetDouble(),
                                              c.GetProperty("nowOffset").GetDouble(), c.GetProperty("lastOffset").GetDouble());
            Check.Equal(c.GetProperty("expect").GetString(), got.LogName(), c.GetProperty("name").GetString()!);
        }
        foreach (var c in spec.GetProperty("nextDayStart").EnumerateArray())
            Check.Near(c.GetProperty("expect").GetDouble(),
                       ScheduleDecision.NextDayStart(c.GetProperty("now").GetDouble(), c.GetProperty("nowOffset").GetDouble(), c.GetProperty("dayStartHour").GetInt32()),
                       what: c.GetProperty("name").GetString()!);
        Check.True(count > 0, "has cases");
    }

    [Test]
    public static void Library()
    {
        var spec = Load("library.json");
        foreach (var c in spec.GetProperty("choose").EnumerateArray())
        {
            var rotation = c.GetProperty("rotation").GetString() switch
            {
                "fixed" => PackRotation.Fixed, "shuffleAll" => PackRotation.ShuffleAll, "shuffleFavorites" => PackRotation.ShuffleFavorites,
                var other => throw new CheckFailed("unknown rotation " + other),
            };
            static List<string> Ids(JsonElement e) => e.EnumerateArray().Select(x => x.GetString()!).ToList();
            var got = PackRotationRules.Choose(rotation, Ids(c.GetProperty("favorites")), Ids(c.GetProperty("available")),
                                               OptionalText(c, "active"), OptionalText(c, "lastPackId"), c.GetProperty("random").GetDouble());
            Check.Equal(OptionalText(c, "expect"), got, c.GetProperty("name").GetString()!);
        }
    }

    [Test]
    public static void Targets()
    {
        var spec = Load("targets.json");
        foreach (var c in spec.GetProperty("windowsMatch").EnumerateArray())
        {
            var id = c.GetProperty("identity");
            var identity = new WindowsTargetIdentity { Path = OptionalText(id, "path"), Package = OptionalText(id, "package"), Exe = OptionalText(id, "exe") };
            Check.Equal(c.GetProperty("expect").GetBoolean(), TargetRules.MatchesWindows(identity, c.GetProperty("imagePath").GetString()!), c.GetProperty("name").GetString()!);
        }
        foreach (var c in spec.GetProperty("choose").EnumerateArray())
        {
            static List<string> Ids(JsonElement e) => e.EnumerateArray().Select(x => x.GetString()!).ToList();
            var rotation = c.GetProperty("rotation").GetString() switch { "shuffleAll" => PackRotation.ShuffleAll, "shuffleFavorites" => PackRotation.ShuffleFavorites, _ => PackRotation.Fixed };
            var (pack, missing) = TargetRules.ChoosePack(OptionalText(c, "animation"), rotation, Ids(c.GetProperty("favorites")), Ids(c.GetProperty("available")),
                                                         OptionalText(c, "active"), OptionalText(c, "lastPackId"), c.GetProperty("random").GetDouble());
            var name = c.GetProperty("name").GetString()!;
            Check.Equal(OptionalText(c, "expect"), pack, name);
            Check.Equal(c.GetProperty("expectMissing").GetBoolean(), missing, name);
        }
        var root = Path.Combine(Path.GetTempPath(), "gardenboot-targets-" + Guid.NewGuid().ToString("N"));
        try
        {
            Directory.CreateDirectory(root);
            var store = new PlaybackStateStore(root);
            foreach (var c in spec.GetProperty("state").EnumerateArray())
            {
                var name = c.GetProperty("name").GetString()!;
                File.WriteAllText(store.Path, c.GetProperty("json").GetRawText());
                var (state, reset) = store.Load();
                if (c.TryGetProperty("expectReset", out var r) && r.GetBoolean()) { Check.True(reset, name); continue; }
                Check.False(reset, name);
                Check.Equal(OptionalDouble(c, "expectSnooze"), state.SnoozeUntil, name);
                foreach (var t in c.GetProperty("expectTargets").EnumerateObject())
                {
                    var view = state.For(t.Name);
                    Check.Equal(OptionalDouble(t.Value, "lastAutoPlayAt"), view.LastAutoPlayAt, name + " " + t.Name);
                    Check.Equal(OptionalText(t.Value, "lastPackId"), view.LastPackId, name + " " + t.Name);
                }
            }
        }
        finally { Directory.Delete(root, true); }
    }

    [Test]
    public static void Compatibility()
    {
        var spec = Load("compatibility.json");
        foreach (var c in spec.GetProperty("verdict").EnumerateArray())
            Check.Equal(c.GetProperty("expect").GetString(), CompatibilityRules.Verdict(c.GetProperty("runningAtStart").GetBoolean(), c.GetProperty("coldStart").GetBoolean(),
                OptionalDouble(c, "windowSeconds"), c.GetProperty("maxWait").GetDouble()).LogName(), c.GetProperty("name").GetString()!);
        foreach (var c in spec.GetProperty("reappear").EnumerateArray())
        {
            var tracker = new ReappearTracker(); var fired = new List<string>(); var i = 0;
            foreach (var x in c.GetProperty("samples").EnumerateArray())
            {
                if (tracker.Feed(x.GetProperty("t").GetDouble(), x.GetProperty("running").GetBoolean(), x.GetProperty("hidden").GetBoolean(),
                                 x.GetProperty("hasWindow").GetBoolean(), x.GetProperty("hasVisibleMain").GetBoolean())) fired.Add(i.ToString());
                i++;
            }
            Check.Sequence(c.GetProperty("expectFired").EnumerateArray().Select(e => e.GetInt32().ToString()), fired, c.GetProperty("name").GetString()!);
        }
        foreach (var c in spec.GetProperty("quiet").EnumerateArray())
        {
            var state = c.GetProperty("state").GetString() switch { "fullscreen" => QuietState.Fullscreen, "game" => QuietState.Game, "presentation" => QuietState.Presentation, _ => QuietState.Normal };
            var (skip, detail) = QuietRules.Skip(c.GetProperty("enabled").GetBoolean(), state);
            Check.Equal(c.GetProperty("expectSkip").GetBoolean(), skip, c.GetProperty("name").GetString()!);
            Check.Equal(OptionalText(c, "expectDetail"), detail, c.GetProperty("name").GetString()!);
        }
    }
    [Test]
    public static void VideoPack()
    {
        var spec = Load("video-pack.json");
        foreach (var c in spec.GetProperty("defaultName").EnumerateArray())
            Check.Equal(c.GetProperty("expect").GetString(), VideoPackRules.DefaultName(c.GetProperty("fileName").GetString()!), c.GetProperty("fileName").GetString()!);
        foreach (var c in spec.GetProperty("extension").EnumerateArray())
            Check.Equal(OptionalText(c, "expect"), VideoPackRules.Extension(c.GetProperty("fileName").GetString()!), c.GetProperty("fileName").GetString()!);
        foreach (var c in spec.GetProperty("validName").EnumerateArray())
            Check.Equal(c.GetProperty("expect").GetBoolean(), VideoPackRules.ValidName(c.GetProperty("name").GetString()!), c.GetProperty("name").GetString()!);
        foreach (var c in spec.GetProperty("makeId").EnumerateArray())
            Check.Equal(c.GetProperty("expect").GetString(), VideoPackRules.MakeId(c.GetProperty("random").GetUInt32()), "makeId");
        foreach (var c in spec.GetProperty("notice").EnumerateArray())
            Check.Equal(c.GetProperty("expect").GetString(), VideoPackRules.Notice(c.GetProperty("name").GetString()!,
                c.GetProperty("sourceFileName").GetString()!, c.GetProperty("date").GetString()!), "notice");

        var root = Path.Combine(Path.GetTempPath(), "video-pack-" + Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(root);
        try
        {
            var video = Path.Combine(root, "My Clip.MOV");
            File.WriteAllText(video, "not decoded here");
            var draws = new Queue<uint>([0u, 0xdeadbeef]);
            var folder = VideoPackRules.Build(video, "  开场  ", new HashSet<string> { "video-00000000" }, Path.Combine(root, "staging"),
                                              new DateTime(2026, 11, 15), draws.Dequeue);
            var pack = PackLibrary.Load(folder);
            Check.Equal("video-deadbeef", pack.Id, "id skips existing");
            Check.Equal("开场", pack.Manifest.Name, "trimmed name");
            Check.Equal("video.mov", pack.Manifest.Segments[PackSegment.Video], "lower-case extension");
            var notice = File.ReadAllText(Path.Combine(folder, "NOTICE.md"));
            Check.True(notice.Contains("「My Clip.MOV」") && !notice.Contains(root), "notice names the file only");
            foreach (var (source, name) in new[] { (Path.Combine(root, "x.avi"), "a"), (video, " ") })
            {
                var threw = false;
                try { VideoPackRules.Build(source, name, new HashSet<string>(), root, DateTime.Now, () => 1); } catch (PackException) { threw = true; }
                Check.True(threw, "rejects " + name);
            }
        }
        finally { Directory.Delete(root, true); }
    }
}
