using System.Globalization;
using System.Text;

namespace GardenBoot.Core;

/// <summary>
/// The built-in "Welcome · 彩虹手写" animation: "welcome" plus the nickname the user set in Sakura
/// (launcher-spec/PACK-FORMAT.md "问候文字", EXPERIENCE-SETTINGS.md "称呼"). Same rules as macOS.
/// </summary>
public static class Greeting
{
    public const int MaxNameLength = 20;
    public const string BuiltInPackId = "sakura-greeting";

    /// <summary>Trims the nickname; blank means none. Throws when it is too long or not a single line.</summary>
    public static string? NormalizedName(string? input)
    {
        var name = input?.Trim();
        if (string.IsNullOrEmpty(name)) return null;
        if (new StringInfo(name).LengthInTextElements > MaxNameLength || name.Any(char.IsControl))
            throw new ExperienceException("称呼最多 20 个字符，请填写一行。");
        return name;
    }

    /// <summary>What the pen writes: lowercase "welcome", then the nickname.</summary>
    public static string ScriptText(string? name) => string.IsNullOrEmpty(name) ? "welcome" : "welcome " + name;

    /// <summary>
    /// Emoji are colour bitmaps with no pen strokes to trace; such names use the plain fade-in lettering instead.
    /// </summary>
    public static bool ScriptCanWrite(string? name)
    {
        if (name is null) return true;
        foreach (var rune in name.EnumerateRunes())
        {
            var v = rune.Value;
            if (v == 0xFE0F || v == 0x200D || v >= 0x1F000 || v is >= 0x2600 and <= 0x27BF || v is >= 0x2B00 and <= 0x2BFF
                || v is >= 0x2190 and <= 0x21FF && Rune.GetUnicodeCategory(rune) == UnicodeCategory.OtherSymbol)
                return false;
        }
        return true;
    }

    /// <summary>The built-in Welcome pack plays no video; Sakura draws it.</summary>
    public static bool IsProcedural(InstalledPack pack) =>
        pack.Id == BuiltInPackId && pack.Manifest.ShowsGreeting && pack.Layout.Intro is not null && pack.Layout.FinalSegment == PackSegment.Outro;
}
