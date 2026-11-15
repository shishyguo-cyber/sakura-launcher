using System.Globalization;
using System.Text.RegularExpressions;

namespace GardenBoot.Core;

/// <summary>"从视频创建动画" (launcher-spec/PACK-FROM-VIDEO.md): turn one local video into a single-video pack.</summary>
public static partial class VideoPackRules
{
    public const string FallbackName = "我的动画";
    public const int MaximumNameLength = 40;

    [GeneratedRegex(@"[_\-\s]+")] private static partial Regex Separators();

    private static int TextLength(string text) => new StringInfo(text).LengthInTextElements;

    public static string DefaultName(string fileName)
    {
        var dot = fileName.LastIndexOf('.');
        var stem = dot >= 0 ? fileName[..dot] : fileName;
        var spaced = Separators().Replace(stem, " ").Trim();
        var info = new StringInfo(spaced);
        var clipped = info.LengthInTextElements > MaximumNameLength ? info.SubstringByTextElements(0, MaximumNameLength).Trim() : spaced;
        return clipped.Length == 0 ? FallbackName : clipped;
    }

    public static string? Extension(string fileName)
    {
        var dot = fileName.LastIndexOf('.');
        if (dot < 0) return null;
        var ext = fileName[(dot + 1)..].ToLowerInvariant();
        return PackDefaults.VideoExtensions.Contains("." + ext) ? ext : null;
    }

    public static bool ValidName(string name)
    {
        var clean = name.Trim();
        return clean.Length > 0 && TextLength(clean) <= MaximumNameLength && !clean.Any(char.IsControl);
    }

    public static string MakeId(uint random) => "video-" + random.ToString("x8", CultureInfo.InvariantCulture);

    public static string Notice(string name, string sourceFileName, string date) =>
        $"# {name}\n\n由 Sakura 从本地视频「{sourceFileName}」创建（{date}）。\n创建者确认这个视频是自己制作的，或有权使用它。\n这个动画包只供个人使用；分享或发布前请自行确认素材权利。\n";

    /// <summary>
    /// Writes the pack folder (manifest, NOTICE.md, a copy of the video) inside <paramref name="parent"/>; the caller
    /// imports it through the normal pack checks and deletes <paramref name="parent"/> afterwards.
    /// </summary>
    public static string Build(string video, string name, IReadOnlySet<string> existingIds, string parent, DateTime now, Func<uint> random)
    {
        var sourceName = Path.GetFileName(video);
        var ext = Extension(sourceName) ?? throw new PackException("请选择 mp4、m4v 或 mov 视频");
        if (!ValidName(name)) throw new PackException("名称需为 1–40 个字符");
        var clean = name.Trim();
        var id = MakeId(random());
        while (existingIds.Contains(id)) id = MakeId(random());
        var folder = Path.Combine(parent, id);
        Directory.CreateDirectory(folder);
        var file = "video." + ext;
        File.Copy(video, Path.Combine(folder, file));
        var manifest = new PackManifest(PackDefaults.SupportedSchema, id, clean, new Dictionary<PackSegment, string> { [PackSegment.Video] = file });
        File.WriteAllText(Path.Combine(folder, PackDefaults.ManifestFile), manifest.ToJson());
        File.WriteAllText(Path.Combine(folder, PackDefaults.NoticeFile),
                          Notice(clean, sourceName, now.ToString("yyyy-MM-dd", CultureInfo.InvariantCulture)));
        return folder;
    }
}
