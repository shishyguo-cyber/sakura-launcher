using System.Text.Json;
using System.Text.RegularExpressions;

namespace GardenBoot.Core;

/// <summary>One video file inside a launch pack.</summary>
public enum PackSegment { Intro, Loop, Outro, Video }

/// <summary>When a waiting loop hands over to the outro after the target window is ready.</summary>
public enum LoopExit { CycleEnd, Immediate }

public sealed class PackException(string message) : Exception(message);

/// <summary>The resolved, validated playback layout of a pack.</summary>
public sealed record PackLayout(string? Intro, string? Loop, string Final, PackSegment FinalSegment)
{
    /// <summary>True when the pack can play while the target is still launching.</summary>
    public bool CoversLaunch => Intro is not null || Loop is not null;
}

public static class PackDefaults
{
    public const double FadeDuration = 0.4;
    public const double SkipFadeDuration = 0.3;
    public const double Volume = 1.0;
    public const double MaxWaitSeconds = 10.0;
    public const string NoticeFile = "NOTICE.md";
    public const string ManifestFile = "manifest.json";
    public const int SupportedSchema = 1;
    public static readonly IReadOnlySet<string> VideoExtensions = new HashSet<string> { ".mp4", ".m4v", ".mov" };
    public static readonly IReadOnlySet<string> ImageExtensions = new HashSet<string> { ".png", ".jpg", ".jpeg" };
    public const long MaxCoverBytes = 8L * 1024 * 1024;
}

/// <summary><c>manifest.json</c> of a launch pack (see launcher-spec/PACK-FORMAT.md). Unknown top-level keys are ignored.</summary>
public sealed record PackManifest(
    int SchemaVersion,
    string Id,
    string Name,
    IReadOnlyDictionary<PackSegment, string> Segments,
    double? HandoffAt = null,
    double? FadeDuration = null,
    double? Volume = null,
    double? MaxWaitSeconds = null,
    LoopExit? LoopExit = null,
    string? Notice = null,
    string? Cover = null,
    VideoFitMode? VideoFit = null,
    string? TextOverlay = null)
{
    private static readonly Regex IdPattern = new("^[a-z0-9][a-z0-9-]{0,63}$", RegexOptions.CultureInvariant);

    public double EffectiveFadeDuration => FadeDuration ?? PackDefaults.FadeDuration;
    public double EffectiveVolume => Volume ?? PackDefaults.Volume;
    public double EffectiveMaxWait => MaxWaitSeconds ?? PackDefaults.MaxWaitSeconds;
    public LoopExit EffectiveLoopExit => LoopExit ?? Core.LoopExit.CycleEnd;
    public string NoticeFile => Notice ?? PackDefaults.NoticeFile;
    public VideoFitMode EffectiveVideoFit => VideoFit ?? VideoFitMode.Auto;
    /// <summary><c>"textOverlay": "greeting"</c>: Sakura draws the greeting (PACK-FORMAT.md "问候文字").</summary>
    public bool ShowsGreeting => TextOverlay == "greeting";

    /// <summary>Parses manifest JSON; throws <see cref="PackException"/> on any type or key error.</summary>
    public static PackManifest Parse(string json)
    {
        JsonDocument doc;
        try { doc = JsonDocument.Parse(json); }
        catch (JsonException) { throw new PackException("JSON 无法解析"); }
        using (doc)
        {
            var root = doc.RootElement;
            if (root.ValueKind != JsonValueKind.Object) throw new PackException("描述必须是 JSON 对象");
            var segments = new Dictionary<PackSegment, string>();
            var raw = Required(root, "segments", JsonValueKind.Object);
            foreach (var entry in raw.EnumerateObject())
            {
                var segment = entry.Name switch
                {
                    "intro" => PackSegment.Intro,
                    "loop" => PackSegment.Loop,
                    "outro" => PackSegment.Outro,
                    "video" => PackSegment.Video,
                    _ => throw new PackException($"未知片段 {entry.Name}"),
                };
                if (entry.Value.ValueKind != JsonValueKind.String) throw new PackException($"{entry.Name} 必须是文件名");
                segments[segment] = entry.Value.GetString()!;
            }
            LoopExit? exit = OptionalString(root, "loopExit") switch
            {
                null => null,
                "cycleEnd" => Core.LoopExit.CycleEnd,
                "immediate" => Core.LoopExit.Immediate,
                var other => throw new PackException($"未知 loopExit {other}"),
            };
            var fitText = OptionalString(root, "videoFit");
            VideoFitMode? fit = fitText is null ? null : VideoFitNames.TryParse(fitText) ?? throw new PackException($"未知 videoFit {fitText}");
            var schema = Required(root, "schemaVersion", JsonValueKind.Number);
            if (!schema.TryGetInt32(out var schemaVersion)) throw new PackException("schemaVersion 必须是整数");
            return new PackManifest(
                schemaVersion,
                Required(root, "id", JsonValueKind.String).GetString()!,
                Required(root, "name", JsonValueKind.String).GetString()!,
                segments,
                OptionalNumber(root, "handoffAt"),
                OptionalNumber(root, "fadeDuration"),
                OptionalNumber(root, "volume"),
                OptionalNumber(root, "maxWaitSeconds"),
                exit,
                OptionalString(root, "notice"),
                OptionalString(root, "cover"),
                fit,
                // Any string is kept for round trips; other shapes mean "no text" (future formats, never an error).
                root.TryGetProperty("textOverlay", out var overlay) && overlay.ValueKind == JsonValueKind.String ? overlay.GetString() : null);
        }
    }

    /// <summary>Writes the manifest in the shared on-disk format.</summary>
    public string ToJson()
    {
        var segments = Segments.ToDictionary(p => p.Key.ToString().ToLowerInvariant(), p => p.Value);
        var body = new Dictionary<string, object?>
        {
            ["schemaVersion"] = SchemaVersion, ["id"] = Id, ["name"] = Name, ["segments"] = segments,
        };
        if (HandoffAt is { } h) body["handoffAt"] = h;
        if (FadeDuration is { } f) body["fadeDuration"] = f;
        if (Volume is { } v) body["volume"] = v;
        if (MaxWaitSeconds is { } w) body["maxWaitSeconds"] = w;
        if (LoopExit is { } e) body["loopExit"] = e == Core.LoopExit.CycleEnd ? "cycleEnd" : "immediate";
        if (Notice is { } n) body["notice"] = n;
        if (Cover is { } cover) body["cover"] = cover;
        if (VideoFit is { } videoFit) body["videoFit"] = videoFit.LogName();
        if (TextOverlay is { } overlay) body["textOverlay"] = overlay;
        return JsonSerializer.Serialize(body, new JsonSerializerOptions { WriteIndented = true });
    }

    /// <summary>Structural validation: everything that can be checked without decoding video.</summary>
    public PackLayout ValidatedLayout()
    {
        if (SchemaVersion != PackDefaults.SupportedSchema) throw new PackException($"不支持的 schemaVersion {SchemaVersion}");
        if (!IdPattern.IsMatch(Id)) throw new PackException("id 只能用小写字母、数字和连字符，最长 64 个字符");
        if (string.IsNullOrWhiteSpace(Name)) throw new PackException("name 不能为空");
        foreach (var file in Segments.Values.Append(NoticeFile)) CheckFileName(file);
        foreach (var (segment, file) in Segments)
        {
            if (!PackDefaults.VideoExtensions.Contains(Path.GetExtension(file).ToLowerInvariant()))
                throw new PackException($"{segment} 必须是 mp4、m4v 或 mov");
        }
        if (Cover is { } c)
        {
            CheckFileName(c);
            if (!PackDefaults.ImageExtensions.Contains(Path.GetExtension(c).ToLowerInvariant()))
                throw new PackException("cover 必须是 png、jpg 或 jpeg 图片");
        }
        if (Volume is { } v && !(v >= 0 && v <= 1)) throw new PackException("volume 需在 0–1 之间");
        if (FadeDuration is { } f && !(f >= 0.1 && f <= 2)) throw new PackException("fadeDuration 需在 0.1–2 秒之间");
        if (MaxWaitSeconds is { } w && !(w >= 1 && w <= 60)) throw new PackException("maxWaitSeconds 需在 1–60 秒之间");
        if (HandoffAt is { } h && !(h >= 0 && double.IsFinite(h))) throw new PackException("handoffAt 不能为负数");

        if (Segments.TryGetValue(PackSegment.Video, out var video))
        {
            if (Segments.Count != 1) throw new PackException("video 不能和 intro、loop、outro 同时使用");
            return new PackLayout(null, null, video, PackSegment.Video);
        }
        if (!Segments.TryGetValue(PackSegment.Outro, out var outro)) throw new PackException("需要 outro，或只提供一个 video");
        return new PackLayout(Segments.GetValueOrDefault(PackSegment.Intro), Segments.GetValueOrDefault(PackSegment.Loop),
                              outro, PackSegment.Outro);
    }

    /// <summary>Fade start inside the final segment, clamped so the fade always fits.</summary>
    public double HandoffTime(double finalDuration)
    {
        var latest = Math.Max(0, finalDuration - EffectiveFadeDuration);
        return HandoffAt is { } h ? Math.Min(Math.Max(0, h), latest) : latest;
    }

    internal static void CheckFileName(string name)
    {
        if (name.Length == 0 || name.Contains('/') || name.Contains('\\') || name is "." or ".." || name.StartsWith('.'))
            throw new PackException($"文件名必须是包内的普通文件：{name}");
    }

    private static JsonElement Required(JsonElement root, string key, JsonValueKind kind)
    {
        if (!root.TryGetProperty(key, out var value)) throw new PackException($"缺少 {key}");
        if (value.ValueKind != kind) throw new PackException($"{key} 类型不对");
        return value;
    }

    private static double? OptionalNumber(JsonElement root, string key)
    {
        if (!root.TryGetProperty(key, out var value) || value.ValueKind == JsonValueKind.Null) return null;
        if (value.ValueKind != JsonValueKind.Number) throw new PackException($"{key} 必须是数字");
        return value.GetDouble();
    }

    private static string? OptionalString(JsonElement root, string key)
    {
        if (!root.TryGetProperty(key, out var value) || value.ValueKind == JsonValueKind.Null) return null;
        if (value.ValueKind != JsonValueKind.String) throw new PackException($"{key} 必须是文字");
        return value.GetString();
    }
}
