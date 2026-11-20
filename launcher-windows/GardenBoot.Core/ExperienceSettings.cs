using System.Globalization;
using System.Text.Json;
using System.Text.Json.Serialization;
using System.Text.RegularExpressions;

namespace GardenBoot.Core;

public sealed class ExperienceException(string message, bool futureVersion = false) : Exception(message)
{
    public bool FutureVersion { get; } = futureVersion;
}

public sealed class PlaybackOverrides
{
    public double? FadeDuration { get; set; }
    public double? HandoffAt { get; set; }
    public double? MaxWaitSeconds { get; set; }
    [JsonConverter(typeof(ExperienceLoopConverter))] public LoopExit? LoopExit { get; set; }
    public double? LaunchCoverage { get; set; }
    [JsonConverter(typeof(VideoFitOverrideConverter))] public VideoFitMode? VideoFit { get; set; }
    public PlaybackOverrides Copy() => (PlaybackOverrides)MemberwiseClone();
    public void Validate()
    {
        foreach (var (value, min, max, name) in new[] { (FadeDuration, .1, 2.0, "淡出时长"), (MaxWaitSeconds, 1.0, 60.0, "最长等待"), (LaunchCoverage, .4, .9, "开场尺寸") })
            if (value is { } v && (!double.IsFinite(v) || v < min || v > max)) throw new ExperienceException($"{name}超出允许范围");
        if (HandoffAt is { } h && (!double.IsFinite(h) || h < 0)) throw new ExperienceException("淡出起点需为非负秒数");
        if (LoopExit is { } e && !Enum.IsDefined(e)) throw new ExperienceException("循环退出方式无效");
        if (VideoFit is { } f && !Enum.IsDefined(f)) throw new ExperienceException("显示方式无效");
    }
}

public sealed class ExperienceLoopConverter : JsonConverter<LoopExit?>
{
    public override LoopExit? Read(ref Utf8JsonReader reader, Type type, JsonSerializerOptions options) =>
        reader.TokenType == JsonTokenType.Null ? null : reader.GetString() switch {
            "cycleEnd" => Core.LoopExit.CycleEnd, "immediate" => Core.LoopExit.Immediate,
            _ => throw new JsonException("未知循环退出方式") };
    public override void Write(Utf8JsonWriter writer, LoopExit? value, JsonSerializerOptions options)
    {
        if (value is null) writer.WriteNullValue();
        else writer.WriteStringValue(value == Core.LoopExit.CycleEnd ? "cycleEnd" : "immediate");
    }
}

public sealed class ExperiencePreset
{
    [JsonRequired] public string Id { get; set; } = Guid.NewGuid().ToString();
    [JsonRequired] public string Name { get; set; } = "";
    [JsonRequired] public PlaybackOverrides Overrides { get; set; } = new();
}
public sealed class PackPreferences
{
    [JsonRequired] public PlaybackOverrides Overrides { get; set; } = new();
    [JsonRequired] public List<ExperiencePreset> Presets { get; set; } = [];
}

/// <summary>Strict string enums: an unknown value is a format error, never a silent default.</summary>
public abstract class StrictEnumConverter<T>(params (T Value, string Name)[] names) : JsonConverter<T> where T : struct, Enum
{
    public override T Read(ref Utf8JsonReader reader, Type type, JsonSerializerOptions options)
    {
        if (reader.TokenType != JsonTokenType.String) throw new JsonException("需要文字");
        var text = reader.GetString();
        foreach (var (value, name) in names) if (name == text) return value;
        throw new JsonException($"未知取值 {text}");
    }
    public override void Write(Utf8JsonWriter writer, T value, JsonSerializerOptions options)
    {
        foreach (var (v, name) in names) if (EqualityComparer<T>.Default.Equals(v, value)) { writer.WriteStringValue(name); return; }
        throw new JsonException("未知取值");
    }
}
public sealed class FrequencyConverter() : StrictEnumConverter<PlayFrequency>((PlayFrequency.EveryLaunch, "everyLaunch"), (PlayFrequency.FirstOfDay, "firstOfDay"));
public sealed class RotationConverter() : StrictEnumConverter<PackRotation>(
    (PackRotation.Fixed, "fixed"), (PackRotation.ShuffleAll, "shuffleAll"), (PackRotation.ShuffleFavorites, "shuffleFavorites"));

/// <summary>schemaVersion 2 <c>playback</c> section.</summary>
public sealed class PlaybackPreferences
{
    [JsonRequired, JsonConverter(typeof(FrequencyConverter))] public PlayFrequency Frequency { get; set; } = PlayFrequency.EveryLaunch;
    [JsonRequired] public int DayStartHour { get; set; } = 4;
    /// <summary>Optional (COMPATIBILITY.md §3); absent means true.</summary>
    public bool QuietWhenFullscreen { get; set; } = true;
}

/// <summary>schemaVersion 2 <c>library</c> section.</summary>
public sealed class LibraryPreferences
{
    public const int MaxFavorites = 200;
    [JsonRequired, JsonConverter(typeof(RotationConverter))] public PackRotation Rotation { get; set; } = PackRotation.Fixed;
    [JsonRequired] public List<string> Favorites { get; set; } = [];
}

public sealed class ExperienceSettings
{
    public const int CurrentSchema = 3;
    private const string FutureMessage = "设置来自较新的软件版本，请升级软件后再编辑。原设置已保留。";
    private static readonly JsonSerializerOptions JsonOptions = new()
    {
        PropertyNamingPolicy = JsonNamingPolicy.CamelCase, WriteIndented = true,
        DefaultIgnoreCondition = JsonIgnoreCondition.WhenWritingNull,
    };
    [JsonRequired] public int SchemaVersion { get; set; } = CurrentSchema;
    [JsonRequired] public double MasterVolume { get; set; } = 1;
    [JsonRequired] public bool Muted { get; set; }
    [JsonRequired] public Dictionary<string, PackPreferences> Packs { get; set; } = new(StringComparer.Ordinal);
    // Required in schemaVersion 2 files; checked in Parse because version 1 files do not have them.
    public PlaybackPreferences Playback { get; set; } = new();
    public LibraryPreferences Library { get; set; } = new();
    /// <summary>schemaVersion 3: the apps Sakura watches (launcher-spec/TARGETS.md).</summary>
    public List<LaunchTarget> Targets { get; set; } = [TargetRules.DefaultWindowsTarget()];
    /// <summary>The nickname the built-in Welcome writes (EXPERIENCE-SETTINGS.md "称呼"); null = just "welcome".</summary>
    public string? GreetingName { get; set; }

    public void Validate()
    {
        if (SchemaVersion > CurrentSchema) throw new ExperienceException(FutureMessage, true);
        if (SchemaVersion != CurrentSchema) throw new ExperienceException("设置版本无效");
        if (Playback is null || Library is null || Library.Favorites is null) throw new ExperienceException("播放或动画库设置缺失");
        TargetRules.Validate(Targets);
        if (GreetingName is not null && Greeting.NormalizedName(GreetingName) != GreetingName) throw new ExperienceException("称呼需去掉首尾空白");
        if (!Enum.IsDefined(Playback.Frequency) || !Enum.IsDefined(Library.Rotation)) throw new ExperienceException("播放或轮换方式无效");
        if (Playback.DayStartHour is < 0 or > 23) throw new ExperienceException("新的一天起点需为 0–23 点");
        if (Library.Favorites.Count > LibraryPreferences.MaxFavorites) throw new ExperienceException($"收藏最多 {LibraryPreferences.MaxFavorites} 个");
        var favorites = new HashSet<string>(StringComparer.Ordinal);
        foreach (var id in Library.Favorites)
            if (id is null || !Regex.IsMatch(id, "^[a-z0-9][a-z0-9-]{0,63}$", RegexOptions.CultureInvariant) || !favorites.Add(id))
                throw new ExperienceException("收藏中的动画包标识无效或重复");
        if (!double.IsFinite(MasterVolume) || MasterVolume < 0 || MasterVolume > 1) throw new ExperienceException("总音量需在 0–100% 之间");
        if (Packs is null) throw new ExperienceException("动画偏好无效");
        foreach (var (id, pack) in Packs)
        {
            if (!Regex.IsMatch(id, "^[a-z0-9][a-z0-9-]{0,63}$", RegexOptions.CultureInvariant) || pack?.Overrides is null || pack.Presets is null)
                throw new ExperienceException("设置中的动画包标识或偏好无效");
            pack.Overrides.Validate();
            var names = new HashSet<string>(StringComparer.Ordinal);
            var ids = new HashSet<string>(StringComparer.Ordinal);
            foreach (var preset in pack.Presets)
            {
                if (preset is null || string.IsNullOrWhiteSpace(preset.Name) || new StringInfo(preset.Name).LengthInTextElements > 40 || preset.Name.Trim() != preset.Name || preset.Name.Any(char.IsControl)
                    || string.IsNullOrEmpty(preset.Id) || preset.Id.Length > 64 || !ids.Add(preset.Id) || preset.Overrides is null)
                    throw new ExperienceException("方案名称需为不重复的 1–40 个字符");
                string canonical;
                try { canonical = preset.Name.Normalize(); }
                catch (ArgumentException) { throw new ExperienceException("方案名称包含无效的 Unicode 字符"); }
                if (!names.Add(canonical)) throw new ExperienceException("方案名称不能重复");
                preset.Overrides.Validate();
            }
        }
    }

    public PackManifest Resolve(PackManifest manifest)
    {
        Validate();
        var o = Packs.GetValueOrDefault(manifest.Id)?.Overrides ?? new();
        var snapshot = manifest with {
            Volume = Muted ? 0 : manifest.EffectiveVolume * MasterVolume,
            FadeDuration = o.FadeDuration ?? manifest.FadeDuration,
            HandoffAt = o.HandoffAt ?? manifest.HandoffAt,
            MaxWaitSeconds = o.MaxWaitSeconds ?? manifest.MaxWaitSeconds,
            LoopExit = o.LoopExit ?? manifest.LoopExit,
            VideoFit = o.VideoFit ?? manifest.VideoFit,
        };
        snapshot.ValidatedLayout();
        return snapshot;
    }
    public double Coverage(string id) => Packs.GetValueOrDefault(id)?.Overrides.LaunchCoverage ?? .72;
    public void ResetPack(string id)
    {
        if (!Packs.TryGetValue(id, out var pack)) Packs[id] = pack = new();
        pack.Overrides = new();
    }
    public void AddPreset(string packId, string name)
    {
        var next = Copy();
        if (!next.Packs.TryGetValue(packId, out var pack)) next.Packs[packId] = pack = new();
        pack.Presets.Add(new() { Name = name.Trim(), Overrides = pack.Overrides.Copy() });
        next.Validate();
        Packs = next.Packs;
    }
    public ExperienceSettings Copy() => Parse(ToJson());
    public string ToJson() { Validate(); return JsonSerializer.Serialize(this, JsonOptions); }
    public static ExperienceSettings Parse(string json)
    {
        try
        {
            using var doc = JsonDocument.Parse(json);
            var root = doc.RootElement;
            if (root.ValueKind != JsonValueKind.Object) throw new JsonException();
            var version = root.TryGetProperty("schemaVersion", out var v) && v.TryGetInt32(out var n) ? n : 0;
            if (version > CurrentSchema) throw new ExperienceException(FutureMessage, true);
            var settings = JsonSerializer.Deserialize<ExperienceSettings>(json, JsonOptions) ?? throw new JsonException();
            if (version == 1)
            {
                // Upgrade: the new sections take their defaults; everything else is kept as written.
                settings.Playback = new();
                settings.Library = new();
            }
            else if (!IsObject(root, "playback") || !IsObject(root, "library")) throw new ExperienceException("播放或动画库设置缺失");
            settings.GreetingName = Greeting.NormalizedName(settings.GreetingName);
            if (version is 1 or 2) { settings.SchemaVersion = CurrentSchema; settings.Targets = [TargetRules.DefaultWindowsTarget()]; }
            else if (!root.TryGetProperty("targets", out var targets) || targets.ValueKind != JsonValueKind.Array) throw new ExperienceException("应用列表缺失");
            settings.Validate();
            return settings;
        }
        catch (Exception e) when (e is JsonException or InvalidOperationException or FormatException or OverflowException)
        { throw new ExperienceException("无法读取个人设置。原文件已保留；保存新设置时会另存恢复副本。"); }
    }

    private static bool IsObject(JsonElement root, string key) =>
        root.TryGetProperty(key, out var value) && value.ValueKind == JsonValueKind.Object;
}
