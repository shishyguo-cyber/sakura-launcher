using System.Text.Json;
using System.Text.Json.Serialization;

namespace GardenBoot.Core;

/// <summary>How a video is shown inside a frame whose aspect differs from the video (launcher-spec/VIDEO-FIT.md).</summary>
public enum VideoFitMode { Auto, Fill, Fit }

public static class VideoFitNames
{
    public static string LogName(this VideoFitMode mode) => mode switch
    {
        VideoFitMode.Fill => "fill", VideoFitMode.Fit => "fit", _ => "auto",
    };

    public static VideoFitMode? TryParse(string? text) => text switch
    {
        "auto" => VideoFitMode.Auto, "fill" => VideoFitMode.Fill, "fit" => VideoFitMode.Fit, _ => null,
    };

    public static VideoFitMode Parse(string text) => TryParse(text) ?? throw new ArgumentException("未知显示方式 " + text);
}

public static class VideoFit
{
    /// <summary>Largest share of the picture that automatic mode may crop while still filling the frame.</summary>
    public const double AutoCropTolerance = 0.12;

    /// <summary>The applied mode (never <see cref="VideoFitMode.Auto"/>) and the sharp video's rect in frame-local coordinates.</summary>
    public static (VideoFitMode Applied, Box Content) Resolve(VideoFitMode mode, double width, double height, double videoAspect)
    {
        if (!(width > 0 && height > 0 && videoAspect > 0 && double.IsFinite(width) && double.IsFinite(height) && double.IsFinite(videoAspect)))
            return (VideoFitMode.Fill, new Box(0, 0, double.IsFinite(width) ? width : 0, double.IsFinite(height) ? height : 0));
        var frameAspect = width / height;
        var crop = 1 - Math.Min(frameAspect, videoAspect) / Math.Max(frameAspect, videoAspect);
        var applied = mode == VideoFitMode.Auto ? (crop <= AutoCropTolerance + 1e-12 ? VideoFitMode.Fill : VideoFitMode.Fit) : mode;
        var scale = applied == VideoFitMode.Fill ? Math.Max(width / videoAspect, height) : Math.Min(width / videoAspect, height);
        var w = videoAspect * scale;
        return (applied, new Box((width - w) / 2, (height - scale) / 2, w, scale));
    }
}

/// <summary>Personal override: null inherits; unknown strings are format errors.</summary>
public sealed class VideoFitOverrideConverter : JsonConverter<VideoFitMode?>
{
    public override VideoFitMode? Read(ref Utf8JsonReader reader, Type type, JsonSerializerOptions options) =>
        reader.TokenType == JsonTokenType.Null ? null
        : reader.TokenType == JsonTokenType.String && VideoFitNames.TryParse(reader.GetString()) is { } mode ? mode
        : throw new JsonException("未知显示方式");
    public override void Write(Utf8JsonWriter writer, VideoFitMode? value, JsonSerializerOptions options)
    {
        if (value is { } mode) writer.WriteStringValue(mode.LogName()); else writer.WriteNullValue();
    }
}
