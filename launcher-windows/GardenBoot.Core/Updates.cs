using System.Globalization;
using System.Text.Json;

namespace GardenBoot.Core;

/// <summary>"检查更新" rules (launcher-spec/UPDATES.md §3): semantic-version precedence and choosing a newer release.</summary>
public static class UpdateRules
{
    public const double CheckInterval = 7 * 24 * 3600;
    public const string ReleasesUrl = "https://api.github.com/repos/shishyguo-cyber/sakura-launcher/releases?per_page=20";

    public sealed record Version(int[] Core, string[] Prerelease)
    {
        public string Text => string.Join('.', Core) + (Prerelease.Length == 0 ? "" : "-" + string.Join('.', Prerelease));
    }

    public sealed record Release(string Tag, string Url, bool Draft, bool Prerelease);
    public sealed record Available(string Version, string Url);

    public static Version? Parse(string? raw)
    {
        if (raw is null) return null;
        var text = raw.Trim();
        if (text.StartsWith('v') || text.StartsWith('V')) text = text[1..];
        if (text.IndexOf('+') is var plus and >= 0) text = text[..plus];
        var dash = text.IndexOf('-');
        var numbers = (dash >= 0 ? text[..dash] : text).Split('.');
        if (numbers.Length != 3) return null;
        var core = new int[3];
        for (var i = 0; i < 3; i++)
        {
            var n = numbers[i];
            if (n.Length == 0 || !n.All(char.IsAsciiDigit) || (n.Length > 1 && n[0] == '0')
                || !int.TryParse(n, NumberStyles.None, CultureInfo.InvariantCulture, out core[i])) return null;
        }
        string[] prerelease = [];
        if (dash >= 0)
        {
            prerelease = text[(dash + 1)..].Split('.');
            if (prerelease.Any(p => p.Length == 0 || !p.All(c => char.IsAsciiLetterOrDigit(c) || c == '-'))) return null;
        }
        return new Version(core, prerelease);
    }

    /// <summary>-1, 0 or 1; null when either side is not a valid version.</summary>
    public static int? Compare(string a, string b) => Parse(a) is { } x && Parse(b) is { } y ? Compare(x, y) : null;

    private static int Compare(Version x, Version y)
    {
        for (var i = 0; i < 3; i++) if (x.Core[i] != y.Core[i]) return x.Core[i] < y.Core[i] ? -1 : 1;
        if (x.Prerelease.Length == 0 || y.Prerelease.Length == 0)
            return x.Prerelease.Length == y.Prerelease.Length ? 0 : x.Prerelease.Length == 0 ? 1 : -1;
        for (var i = 0; i < Math.Min(x.Prerelease.Length, y.Prerelease.Length); i++)
        {
            string p = x.Prerelease[i], q = y.Prerelease[i];
            if (p == q) continue;
            var pn = p.All(char.IsAsciiDigit); var qn = q.All(char.IsAsciiDigit);
            if (pn && qn) return long.Parse(p, CultureInfo.InvariantCulture) < long.Parse(q, CultureInfo.InvariantCulture) ? -1 : 1;
            if (pn != qn) return pn ? -1 : 1;
            return string.CompareOrdinal(p, q) < 0 ? -1 : 1;
        }
        return x.Prerelease.Length == y.Prerelease.Length ? 0 : x.Prerelease.Length < y.Prerelease.Length ? -1 : 1;
    }

    public static Available? Newest(IEnumerable<Release> releases, string current)
    {
        if (Parse(current) is not { } now) return null;
        var allowPrerelease = now.Prerelease.Length > 0;
        (Version Version, Release Release)? best = null;
        foreach (var release in releases)
        {
            if (release.Draft || Parse(release.Tag) is not { } version) continue;
            if (!allowPrerelease && (version.Prerelease.Length > 0 || release.Prerelease)) continue;
            if (Compare(version, now) <= 0) continue;
            if (best is null || Compare(version, best.Value.Version) > 0) best = (version, release);
        }
        return best is { } b ? new Available(b.Version.Text, b.Release.Url) : null;
    }

    public static bool IsDue(double? lastCheckAt, double now) =>
        lastCheckAt is not { } last || now < last || now - last >= CheckInterval;

    /// <summary>GitHub's release list; malformed entries and non-https links are skipped.</summary>
    public static IReadOnlyList<Release> DecodeReleases(string json)
    {
        using var document = JsonDocument.Parse(json);
        if (document.RootElement.ValueKind != JsonValueKind.Array) throw new JsonException("not a release list");
        var result = new List<Release>();
        foreach (var item in document.RootElement.EnumerateArray())
        {
            if (item.ValueKind != JsonValueKind.Object
                || !item.TryGetProperty("tag_name", out var tag) || tag.ValueKind != JsonValueKind.String
                || !item.TryGetProperty("html_url", out var url) || url.ValueKind != JsonValueKind.String
                || !url.GetString()!.StartsWith("https://", StringComparison.Ordinal)) continue;
            bool Flag(string name) => item.TryGetProperty(name, out var v) && v.ValueKind == JsonValueKind.True;
            result.Add(new Release(tag.GetString()!, url.GetString()!, Flag("draft"), Flag("prerelease")));
        }
        return result;
    }
}
