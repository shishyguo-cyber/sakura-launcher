using System.Text.Json;
using System.Text.RegularExpressions;

namespace GardenBoot.Core;

/// <summary>How often automatic playback may happen (launcher-spec/SCHEDULE-AND-LIBRARY.md §2).</summary>
public enum PlayFrequency { EveryLaunch, FirstOfDay }

public enum ScheduleOutcome { Play, Snoozed, PlayedToday }

public static class ScheduleOutcomeNames
{
    public static string LogName(this ScheduleOutcome outcome) => outcome switch
    {
        ScheduleOutcome.Play => "play", ScheduleOutcome.Snoozed => "snoozed", _ => "playedToday",
    };
}

/// <summary>What one target app last played.</summary>
public sealed class TargetPlayback
{
    public double? LastAutoPlayAt { get; set; }
    public string? LastPackId { get; set; }
    /// <summary>Last "测试一下" result (COMPATIBILITY.md §1).</summary>
    public CompatResult? Compat { get; set; }
}

public sealed record CompatResult(CompatVerdict Verdict, double? WindowSeconds, double At);

/// <summary>
/// Re-creatable runtime state kept in <c>playback-state.json</c>. Times are Unix seconds. The snooze is global; the
/// last play is per target (schemaVersion 2). <see cref="LastAutoPlayAt"/>/<see cref="LastPackId"/> are the view of one
/// target handed to <see cref="ScheduleDecision.Decide"/>; they are not stored at the top level.
/// </summary>
public sealed class PlaybackState
{
    public double? LastAutoPlayAt { get; set; }
    public string? LastPackId { get; set; }
    public double? SnoozeUntil { get; set; }
    public Dictionary<string, TargetPlayback> Targets { get; set; } = new(StringComparer.Ordinal);

    /// <summary>This target's last play plus the global snooze, for decisions.</summary>
    public PlaybackState For(string targetId)
    {
        var t = Targets.GetValueOrDefault(targetId);
        return new() { SnoozeUntil = SnoozeUntil, LastAutoPlayAt = t?.LastAutoPlayAt, LastPackId = t?.LastPackId };
    }

    public void Record(string targetId, double at, string packId)
    {
        var entry = Targets.TryGetValue(targetId, out var existing) ? existing : Targets[targetId] = new();
        entry.LastAutoPlayAt = at; entry.LastPackId = packId;
    }

    public void RecordCompat(string targetId, CompatResult result) =>
        (Targets.TryGetValue(targetId, out var existing) ? existing : Targets[targetId] = new()).Compat = result;

    internal static readonly Regex IdPattern = new("^[a-z0-9][a-z0-9-]{0,63}$", RegexOptions.CultureInvariant);

    public void Validate()
    {
        foreach (var (value, name) in new[] { (LastAutoPlayAt, "lastAutoPlayAt"), (SnoozeUntil, "snoozeUntil") })
            if (value is { } v && (!double.IsFinite(v) || v < 0)) throw new ArgumentException($"{name} 必须是非负秒数");
        if (LastPackId is { } id && !IdPattern.IsMatch(id)) throw new ArgumentException("lastPackId 无效");
        foreach (var (target, value) in Targets)
        {
            if (!IdPattern.IsMatch(target) || value is null) throw new ArgumentException("目标标识无效");
            if (value.LastAutoPlayAt is { } at && (!double.IsFinite(at) || at < 0)) throw new ArgumentException("lastAutoPlayAt 必须是非负秒数");
            if (value.LastPackId is { } pack && !IdPattern.IsMatch(pack)) throw new ArgumentException("lastPackId 无效");
        }
    }

    /// <summary>The snooze end if it is still in the future, else null.</summary>
    public double? ActiveSnooze(double now) => SnoozeUntil is { } s && now < s ? s : null;
}

public static class ScheduleDecision
{
    /// <summary>Allowed clock skew before a "future" last-play time is treated as a clock moved back.</summary>
    public const double FutureTolerance = 300;

    public static long DayKey(double time, double offset, int dayStartHour) =>
        (long)Math.Floor((time + offset - dayStartHour * 3600.0) / 86400);

    public static ScheduleOutcome Decide(PlayFrequency frequency, int dayStartHour, PlaybackState state,
                                         double now, double nowOffset, double lastOffset)
    {
        if (state.SnoozeUntil is { } snooze && now < snooze) return ScheduleOutcome.Snoozed;
        if (frequency == PlayFrequency.EveryLaunch) return ScheduleOutcome.Play;
        if (state.LastAutoPlayAt is not { } last) return ScheduleOutcome.Play;
        if (last > now + FutureTolerance) return ScheduleOutcome.Play;
        return DayKey(now, nowOffset, dayStartHour) != DayKey(last, lastOffset, dayStartHour)
            ? ScheduleOutcome.Play : ScheduleOutcome.PlayedToday;
    }

    /// <summary>The next local <paramref name="dayStartHour"/>:00 after <paramref name="now"/>, using the offset at now.</summary>
    public static double NextDayStart(double now, double nowOffset, int dayStartHour) =>
        (DayKey(now, nowOffset, dayStartHour) + 1) * 86400.0 + dayStartHour * 3600.0 - nowOffset;
}

/// <summary><c>playback-state.json</c>: missing or unreadable means empty; writes are atomic.</summary>
public sealed class PlaybackStateStore(string directory)
{
    public string Path => System.IO.Path.Combine(directory, "playback-state.json");

    /// <summary>Returns the state and whether an existing file had to be discarded.</summary>
    public (PlaybackState State, bool WasReset) Load()
    {
        if (!File.Exists(Path)) return (new(), false);
        try
        {
            using var doc = JsonDocument.Parse(File.ReadAllText(Path));
            var root = doc.RootElement;
            if (root.ValueKind != JsonValueKind.Object || !root.TryGetProperty("schemaVersion", out var v)
                || !v.TryGetInt32(out var version) || version is not (1 or 2)) return (new(), true);
            var state = new PlaybackState { SnoozeUntil = Number(root, "snoozeUntil") };
            if (version == 1)
            {
                var at = Number(root, "lastAutoPlayAt"); var pack = Text(root, "lastPackId");
                if (at is not null || pack is not null) state.Targets[TargetRules.DefaultId] = new() { LastAutoPlayAt = at, LastPackId = pack };
            }
            else if (root.TryGetProperty("targets", out var targets) && targets.ValueKind != JsonValueKind.Null)
            {
                if (targets.ValueKind != JsonValueKind.Object) throw new FormatException("targets");
                foreach (var entry in targets.EnumerateObject())
                {
                    if (entry.Value.ValueKind != JsonValueKind.Object) throw new FormatException("target");
                    CompatResult? compat = null;
                    if (entry.Value.TryGetProperty("compat", out var c) && c.ValueKind == JsonValueKind.Object
                        && CompatibilityRules.Parse(Text(c, "verdict")) is { } verdict && Number(c, "at") is { } at)
                        compat = new(verdict, Number(c, "windowSeconds"), at);
                    state.Targets[entry.Name] = new() { LastAutoPlayAt = Number(entry.Value, "lastAutoPlayAt"), LastPackId = Text(entry.Value, "lastPackId"), Compat = compat };
                }
            }
            state.Validate();
            return (state, false);
        }
        catch (Exception e) when (e is JsonException or IOException or UnauthorizedAccessException or InvalidOperationException
                                   or FormatException or ArgumentException)
        { return (new(), true); }
    }

    public void Save(PlaybackState state)
    {
        state.Validate();
        var body = new Dictionary<string, object?>
        {
            ["schemaVersion"] = 2, ["snoozeUntil"] = state.SnoozeUntil,
            ["targets"] = state.Targets.ToDictionary(t => t.Key, t => new Dictionary<string, object?>
            {
                ["lastAutoPlayAt"] = t.Value.LastAutoPlayAt, ["lastPackId"] = t.Value.LastPackId,
                ["compat"] = t.Value.Compat is { } c
                    ? new Dictionary<string, object?> { ["verdict"] = c.Verdict.LogName(), ["windowSeconds"] = c.WindowSeconds, ["at"] = c.At } : null,
            }),
        };
        Directory.CreateDirectory(directory);
        var temporary = System.IO.Path.Combine(directory, $".playback-state-{Guid.NewGuid():N}.tmp");
        try
        {
            File.WriteAllText(temporary, JsonSerializer.Serialize(body, new JsonSerializerOptions { WriteIndented = true }));
            File.Move(temporary, Path, true);
        }
        finally { if (File.Exists(temporary)) File.Delete(temporary); }
    }

    private static double? Number(JsonElement root, string key)
    {
        if (!root.TryGetProperty(key, out var v) || v.ValueKind == JsonValueKind.Null) return null;
        if (v.ValueKind != JsonValueKind.Number) throw new FormatException(key);
        return v.GetDouble();
    }

    private static string? Text(JsonElement root, string key)
    {
        if (!root.TryGetProperty(key, out var v) || v.ValueKind == JsonValueKind.Null) return null;
        if (v.ValueKind != JsonValueKind.String) throw new FormatException(key);
        return v.GetString();
    }
}
