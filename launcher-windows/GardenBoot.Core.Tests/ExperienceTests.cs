using System.Text.Json;
namespace GardenBoot.Core.Tests;

public static class ExperienceTests
{
    private static PackManifest Manifest => new(1, "a", "A", new Dictionary<PackSegment, string> { [PackSegment.Outro] = "outro.mp4" }, Volume: .8);

    [Test] public static void SharedResolution()
    {
        var dir = new DirectoryInfo(AppContext.BaseDirectory);
        while (dir is not null && !Directory.Exists(Path.Combine(dir.FullName, "launcher-spec"))) dir = dir.Parent;
        using var fixture = JsonDocument.Parse(File.ReadAllText(Path.Combine(dir!.FullName, "launcher-spec/conformance/experience.json")));
        foreach (var c in fixture.RootElement.GetProperty("cases").EnumerateArray())
        {
            var json = c.GetProperty("settings").GetRawText();
            if (!c.GetProperty("valid").GetBoolean()) { Check.Throws<ExperienceException>(() => ExperienceSettings.Parse(json), c.GetProperty("name").GetString()!); continue; }
            var settings = ExperienceSettings.Parse(json);
            var resolved = settings.Resolve(Manifest);
            var e = c.GetProperty("expect");
            Check.Near(e.GetProperty("volume").GetDouble(), resolved.EffectiveVolume);
            Check.Near(e.GetProperty("fadeDuration").GetDouble(), resolved.EffectiveFadeDuration);
            Check.Near(e.GetProperty("maxWaitSeconds").GetDouble(), resolved.EffectiveMaxWait);
            Check.Equal(e.GetProperty("loopExit").GetString(), resolved.EffectiveLoopExit == LoopExit.CycleEnd ? "cycleEnd" : "immediate");
            Check.Near(e.GetProperty("launchCoverage").GetDouble(), settings.Coverage("a"));
            Check.Near(e.GetProperty("handoffTime").GetDouble(), resolved.HandoffTime(10));
            Check.Near(.8, Manifest.EffectiveVolume);
            Check.Equal(3, settings.SchemaVersion, "decoded settings are schema 3");
            if (c.TryGetProperty("expectTargets", out var et))
                Check.Sequence(et.EnumerateArray().Select(x => x.GetString()!), settings.Targets.Select(x => x.Id), c.GetProperty("name").GetString()!);
            if (c.TryGetProperty("expectVideoFit", out var vf))
                Check.Equal(vf.GetString(), resolved.EffectiveVideoFit.LogName(), c.GetProperty("name").GetString()!);
            if (c.TryGetProperty("expectPlayback", out var pb))
            {
                Check.Equal(pb.GetProperty("frequency").GetString(), settings.Playback.Frequency == PlayFrequency.FirstOfDay ? "firstOfDay" : "everyLaunch");
                Check.Equal(pb.GetProperty("dayStartHour").GetInt32(), settings.Playback.DayStartHour);
            }
            if (c.TryGetProperty("expectLibrary", out var lb))
            {
                Check.Equal(lb.GetProperty("rotation").GetString(), settings.Library.Rotation.LogName());
                Check.Sequence(lb.GetProperty("favorites").EnumerateArray().Select(x => x.GetString()!), settings.Library.Favorites);
            }
        }
    }

    [Test] public static void PresetSnapshotAndResetAreIsolated()
    {
        var settings = new ExperienceSettings();
        settings.Packs["a"] = new() { Overrides = new() { FadeDuration = 1.2 } };
        settings.Packs["b"] = new() { Overrides = new() { MaxWaitSeconds = 25 } };
        settings.AddPreset("a", "  轻柔  ");
        settings.Packs["a"].Overrides.FadeDuration = 2;
        Check.Near(1.2, settings.Packs["a"].Presets[0].Overrides.FadeDuration!.Value);
        settings.ResetPack("a");
        Check.True(settings.Packs["a"].Overrides.FadeDuration is null);
        Check.Equal("轻柔", settings.Packs["a"].Presets[0].Name);
        Check.Near(25, settings.Packs["b"].Overrides.MaxWaitSeconds!.Value);
        Check.Throws<ExperienceException>(() => settings.AddPreset("a", "轻柔"));
        Check.Throws<ExperienceException>(() => settings.AddPreset("a", "\n "));
        Check.Throws<ExperienceException>(() => settings.AddPreset("a", "\uD800"));
    }

    [Test] public static void StoreRoundTripCorruptRecoveryAndFutureProtection()
    {
        var root = Path.Combine(Path.GetTempPath(), Guid.NewGuid().ToString());
        try
        {
            var store = new ExperienceStore(root);
            Check.Near(1, store.Load().MasterVolume);
            var settings = new ExperienceSettings { MasterVolume = .35 };
            settings.AddPreset("a", "我的方案");
            store.Save(settings);
            Check.Equal(settings.ToJson(), store.Load().ToJson());
            File.WriteAllText(store.Path, "{broken");
            Check.Throws<ExperienceException>(() => store.Load());
            Check.Equal("{broken", File.ReadAllText(store.Path));
            store.Save(settings);
            Check.Equal("{broken", File.ReadAllText(Directory.GetFiles(root, "experience.recovery-*.json").Single()));
            File.WriteAllText(store.Path, "{\"schemaVersion\":99}");
            Check.Throws<ExperienceException>(() => store.Save(settings));
            Check.Equal("{\"schemaVersion\":99}", File.ReadAllText(store.Path));
        }
        finally { if (Directory.Exists(root)) Directory.Delete(root, true); }
    }

    [Test] public static void InvalidSavePreservesPreviousSettings()
    {
        var root = Path.Combine(Path.GetTempPath(), Guid.NewGuid().ToString());
        try
        {
            var store = new ExperienceStore(root);
            store.Save(new());
            var before = File.ReadAllText(store.Path);
            Check.Throws<ExperienceException>(() => store.Save(new() { MasterVolume = double.NaN }));
            Check.Equal(before, File.ReadAllText(store.Path));
            var settings = new ExperienceSettings();
            settings.Packs["a"] = new() { Overrides = new() { FadeDuration = .4 } };
            Check.Near(.4, settings.Resolve(Manifest with { FadeDuration = 1.8 }).EffectiveFadeDuration);
            settings.ResetPack("a");
            Check.Near(1.8, settings.Resolve(Manifest with { FadeDuration = 1.8 }).EffectiveFadeDuration);
        }
        finally { if (Directory.Exists(root)) Directory.Delete(root, true); }
    }

    [Test] public static void CustomCoverageStaysOnScreen()
    {
        var screen = new Box(0, 0, 1920, 1080);
        Check.Equal(new Box(576, 324, 768, 432), OverlayGeometry.LaunchFrame(screen, coverage: .4));
        Check.Equal(new Box(400, 225, 1120, 630), OverlayGeometry.LaunchFrame(screen, coverage: .9));
        Check.Near(-1344, OverlayGeometry.LaunchFrame(new(-1920, 0, 1920, 1080), coverage: .4).X);
        Check.Equal(OverlayGeometry.LaunchFrame(screen), OverlayGeometry.LaunchFrame(screen, coverage: double.NaN));
    }

    [Test] public static void V1FileUpgradesOnSaveAndKeepsValues()
    {
        var root = Path.Combine(Path.GetTempPath(), Guid.NewGuid().ToString());
        try
        {
            Directory.CreateDirectory(root);
            var store = new ExperienceStore(root);
            File.WriteAllText(store.Path, """
                {"schemaVersion":1,"masterVolume":0.4,"muted":true,
                 "packs":{"a":{"overrides":{"fadeDuration":1.1},"presets":[{"id":"p1","name":"安静","overrides":{"maxWaitSeconds":5}}]}}}
                """);
            var loaded = store.Load();
            Check.Equal(PlayFrequency.EveryLaunch, loaded.Playback.Frequency);
            Check.Equal(4, loaded.Playback.DayStartHour);
            Check.Equal(PackRotation.Fixed, loaded.Library.Rotation);
            loaded.Playback.Frequency = PlayFrequency.FirstOfDay;
            loaded.Library.Favorites.Add("a");
            store.Save(loaded);
            Check.Equal(0, Directory.GetFiles(root, "experience.recovery-*.json").Length, "a valid v1 file is not treated as corrupt");
            using var doc = JsonDocument.Parse(File.ReadAllText(store.Path));
            Check.Equal(3, doc.RootElement.GetProperty("schemaVersion").GetInt32());
            Check.Equal("default-codex", doc.RootElement.GetProperty("targets")[0].GetProperty("id").GetString());
            Check.Equal("firstOfDay", doc.RootElement.GetProperty("playback").GetProperty("frequency").GetString());
            Check.Equal("fixed", doc.RootElement.GetProperty("library").GetProperty("rotation").GetString());
            var again = store.Load();
            Check.Near(.4, again.MasterVolume);
            Check.True(again.Muted);
            Check.Near(1.1, again.Packs["a"].Overrides.FadeDuration!.Value);
            Check.Equal("安静", again.Packs["a"].Presets.Single().Name);
            Check.Sequence(["a"], again.Library.Favorites);
            var copy = again.Copy();
            copy.Library.Favorites.Add("b");
            Check.Sequence(["a"], again.Library.Favorites, "copies are independent");
            File.WriteAllText(store.Path, """{"schemaVersion":4,"masterVolume":1,"muted":false,"packs":{}}""");
            Check.True(Check.Throws<ExperienceException>(() => store.Load()).FutureVersion);
        }
        finally { if (Directory.Exists(root)) Directory.Delete(root, true); }
    }
}
