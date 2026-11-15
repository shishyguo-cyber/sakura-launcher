namespace GardenBoot.Core.Tests;

/// <summary>playback-state.json storage (SCHEDULE-AND-LIBRARY.md §1).</summary>
public static class ScheduleTests
{
    private static string NewRoot() => Path.Combine(Path.GetTempPath(), "gardenboot-state-" + Guid.NewGuid().ToString("N"));

    [Test]
    public static void StateRoundTripsAndMissingFileIsEmpty()
    {
        var root = NewRoot();
        try
        {
            var store = new PlaybackStateStore(root);
            var (empty, reset) = store.Load();
            Check.True(empty.LastAutoPlayAt is null && empty.LastPackId is null && empty.SnoozeUntil is null);
            Check.False(reset, "a missing file is not a reset");
            var saved = new PlaybackState { SnoozeUntil = 1794650000 };
            saved.Record("default-codex", 1794643200.5, "demo-garden");
            saved.Record("chrome-1", 1794643300, "night-garden");
            store.Save(saved);
            var (loaded, wasReset) = store.Load();
            Check.False(wasReset);
            Check.Near(1794643200.5, loaded.For("default-codex").LastAutoPlayAt!.Value);
            Check.Equal("demo-garden", loaded.For("default-codex").LastPackId);
            Check.Equal("night-garden", loaded.For("chrome-1").LastPackId);
            Check.True(loaded.For("never-played").LastAutoPlayAt is null);
            Check.Near(1794650000, loaded.For("chrome-1").SnoozeUntil!.Value);
            saved.RecordCompat("chrome-1", new(CompatVerdict.Good, 2.1, 1794643400));
            store.Save(saved);
            var compat = store.Load().State.Targets["chrome-1"];
            Check.Equal(CompatVerdict.Good, compat.Compat!.Verdict);
            Check.Near(2.1, compat.Compat.WindowSeconds!.Value);
            Check.Equal("night-garden", compat.LastPackId, "recording a test result keeps the last play");
            Check.Equal(0, Directory.GetFiles(root, "*.tmp").Length, "no temporary file left");
        }
        finally { if (Directory.Exists(root)) Directory.Delete(root, true); }
    }

    [Test]
    public static void BadStateIsTreatedAsEmpty()
    {
        var root = NewRoot();
        try
        {
            Directory.CreateDirectory(root);
            var store = new PlaybackStateStore(root);
            foreach (var text in new[] {
                "{broken", """{"schemaVersion":3}""", """{"schemaVersion":1,"lastAutoPlayAt":-1}""", """{"schemaVersion":2,"targets":{"a":{"lastAutoPlayAt":-1}}}""",
                """{"schemaVersion":1,"lastPackId":"Bad Id"}""", """{"schemaVersion":1,"snoozeUntil":"soon"}""", "[]" })
            {
                File.WriteAllText(store.Path, text);
                var (state, reset) = store.Load();
                Check.True(reset, text);
                Check.True(state.Targets.Count == 0 && state.SnoozeUntil is null, text);
            }
            Check.Throws<ArgumentException>(() => store.Save(new PlaybackState { LastAutoPlayAt = double.NaN }));
        }
        finally { if (Directory.Exists(root)) Directory.Delete(root, true); }
    }
}
