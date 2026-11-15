using System.Globalization;
using System.Text.Json.Serialization;
using System.Text.RegularExpressions;

namespace GardenBoot.Core;

/// <summary>macOS identity of a target app (kept and saved untouched on Windows).</summary>
public sealed class MacTargetIdentity
{
    public string? BundleId { get; set; }
}

/// <summary>Windows identity: either a packaged app (<c>package</c> + optional <c>exe</c>) or an exe path.</summary>
public sealed class WindowsTargetIdentity
{
    public string? Package { get; set; }
    public string? Exe { get; set; }
    public string? Path { get; set; }
}

/// <summary>One app Sakura plays a launch animation for (launcher-spec/TARGETS.md).</summary>
public sealed class LaunchTarget
{
    [JsonRequired] public string Id { get; set; } = "";
    [JsonRequired] public string Name { get; set; } = "";
    [JsonRequired] public bool Enabled { get; set; } = true;
    /// <summary>null follows the global animation and rotation.</summary>
    public string? Animation { get; set; }
    /// <summary>Optional (COMPATIBILITY.md §2): also play when the running app brings a window back.</summary>
    public bool PlayOnReappear { get; set; }
    public MacTargetIdentity? Mac { get; set; }
    public WindowsTargetIdentity? Windows { get; set; }
}

public static class TargetRules
{
    public const string DefaultId = "default-codex";
    public const int MaxTargets = 20;
    private static readonly Regex IdPattern = new("^[a-z0-9][a-z0-9-]{0,63}$", RegexOptions.CultureInvariant);
    private static readonly Regex AbsoluteWindowsPath = new(@"^([A-Za-z]:\\|\\\\)", RegexOptions.CultureInvariant);

    /// <summary>The ChatGPT/Codex target every installation starts with.</summary>
    public static LaunchTarget DefaultWindowsTarget() => new()
    {
        Id = DefaultId, Name = "ChatGPT", Enabled = true,
        Windows = new() { Package = "OpenAI.Codex", Exe = @"app\ChatGPT.exe" },
    };

    public static bool MatchesWindows(WindowsTargetIdentity identity, string imagePath)
    {
        if (identity.Path is { } path) return string.Equals(path, imagePath, StringComparison.OrdinalIgnoreCase);
        if (identity.Package is not { Length: > 0 } package) return false;
        if (imagePath.IndexOf(@"\WindowsApps\" + package + "_", StringComparison.OrdinalIgnoreCase) < 0) return false;
        return identity.Exe is not { Length: > 0 } exe || imagePath.EndsWith(@"\" + exe, StringComparison.OrdinalIgnoreCase);
    }

    /// <summary>The target's own animation when available; otherwise the global choice. Missing = its own pack was unavailable.</summary>
    public static (string? Pack, bool Missing) ChoosePack(string? animation, PackRotation rotation, IReadOnlyCollection<string> favorites,
                                                         IReadOnlyList<string> available, string? active, string? lastPackId, double random)
    {
        if (animation is not null && available.Contains(animation, StringComparer.Ordinal)) return (animation, false);
        return (PackRotationRules.Choose(rotation, favorites, available, active, lastPackId, random), animation is not null);
    }

    public static string WindowsKey(WindowsTargetIdentity w) =>
        w.Path is { } p ? "path:" + p.ToUpperInvariant() : "pkg:" + (w.Package ?? "").ToUpperInvariant() + "|" + (w.Exe ?? "").ToUpperInvariant();

    public static void Validate(IReadOnlyList<LaunchTarget>? targets)
    {
        if (targets is null) throw new ExperienceException("应用列表缺失");
        if (targets.Count > MaxTargets) throw new ExperienceException($"最多添加 {MaxTargets} 个应用");
        var ids = new HashSet<string>(StringComparer.Ordinal);
        var macs = new HashSet<string>(StringComparer.Ordinal);
        var windows = new HashSet<string>(StringComparer.Ordinal);
        foreach (var t in targets)
        {
            if (t is null || t.Id is null || !IdPattern.IsMatch(t.Id) || !ids.Add(t.Id)) throw new ExperienceException("应用标识无效或重复");
            if (t.Name is null || string.IsNullOrWhiteSpace(t.Name) || t.Name.Trim() != t.Name || t.Name.Any(char.IsControl)
                || new StringInfo(t.Name).LengthInTextElements > 40) throw new ExperienceException("应用名称需为 1–40 个字符");
            if (t.Animation is { } a && !IdPattern.IsMatch(a)) throw new ExperienceException("应用绑定的动画标识无效");
            if (t.Mac is { } m)
            {
                if (string.IsNullOrEmpty(m.BundleId) || m.BundleId.Length > 255) throw new ExperienceException("应用的 macOS 标识无效");
                if (!macs.Add(m.BundleId)) throw new ExperienceException("同一个应用不能重复添加");
            }
            if (t.Windows is { } w)
            {
                var hasPath = w.Path is not null; var hasPackage = w.Package is not null || w.Exe is not null;
                if (hasPath == hasPackage) throw new ExperienceException("应用的 Windows 标识需为程序路径或应用包之一");
                if (hasPath && !AbsoluteWindowsPath.IsMatch(w.Path!)) throw new ExperienceException("应用程序路径需为完整路径");
                if (hasPackage && string.IsNullOrWhiteSpace(w.Package)) throw new ExperienceException("应用包名称不能为空");
                if (!windows.Add(WindowsKey(w))) throw new ExperienceException("同一个应用不能重复添加");
            }
        }
    }
}
