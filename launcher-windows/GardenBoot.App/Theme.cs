using System.Windows;
using System.Windows.Interop;
using System.Windows.Media;
using Microsoft.Win32;

namespace GardenBoot.App;

/// <summary>Colour tokens from launcher-spec/DESIGN.md §1, following the Windows light/dark setting (read only).</summary>
internal static class Theme
{
    private const string Personalize = @"Software\Microsoft\Windows\CurrentVersion\Themes\Personalize";

    private static readonly (string Key, uint Light, uint Dark)[] Tokens =
    [
        ("Bg", 0xFBFAF7, 0x18171C), ("Sidebar", 0xF3F0EA, 0x121116), ("Surface", 0xFFFFFF, 0x211F27), ("Hover", 0xECE8E0, 0x2A2731),
        ("Border", 0xE6E1D8, 0x34313C), ("Divider", 0xEFEBE4, 0x2B2832), ("Text", 0x2B2A33, 0xEEECF2), ("TextSecondary", 0x6B6776, 0xA8A3B3),
        ("Accent", 0x6B4FC0, 0xB9A6F2), ("AccentFill", 0x8A6FD1, 0x9D86E6), ("AccentSoft", 0xECE7F7, 0x2C2638), ("OnAccent", 0xFFFFFF, 0x16131D),
        ("Hero", 0xE9F1EA, 0x1E2B23), ("HeroText", 0x24402E, 0xDCEBDD), ("HeroSecondary", 0x4E6B57, 0x9FBBA5),
        ("Danger", 0xB3423F, 0xE07A76), ("Success", 0x3C7D5A, 0x7CC39C),
    ];

    public static Color Token(string key, bool dark) => ColorOf(Tokens.First(t => t.Key == key) is var t ? (dark ? t.Dark : t.Light) : 0);

    /// <summary>Tests force a mode; null follows the system.</summary>
    public static bool? Override { get; set; }

    public static bool AppsDark => Override ?? ReadDark("AppsUseLightTheme");
    public static bool TaskbarDark => ReadDark("SystemUsesLightTheme");

    private static bool ReadDark(string name)
    {
        try
        {
            using var key = Registry.CurrentUser.OpenSubKey(Personalize);
            return key?.GetValue(name) is int value && value == 0;
        }
        catch (Exception e) when (e is System.Security.SecurityException or UnauthorizedAccessException or System.IO.IOException) { return false; }
    }

    public static Color ColorOf(uint rgb) => Color.FromRgb((byte)(rgb >> 16), (byte)(rgb >> 8), (byte)rgb);

    /// <summary>Puts the brushes and control styles into <paramref name="resources"/>; call again to switch modes.</summary>
    public static void Apply(ResourceDictionary resources, bool dark)
    {
        foreach (var (key, light, darkValue) in Tokens)
        {
            var brush = new SolidColorBrush(ColorOf(dark ? darkValue : light));
            brush.Freeze();
            resources[key] = brush;
        }
        if (!resources.MergedDictionaries.Any(d => d.Source?.OriginalString.EndsWith("Styles.xaml", StringComparison.Ordinal) == true))
            resources.MergedDictionaries.Add(new ResourceDictionary { Source = new Uri("pack://application:,,,/Sakura;component/Styles.xaml") });
    }

    public static Brush Brush(FrameworkElement owner, string key) => (Brush)owner.FindResource(key);

    /// <summary>Dark title bar to match (Windows 10 2004+/11; ignored elsewhere).</summary>
    public static void UseDarkTitleBar(Window window, bool dark)
    {
        var handle = new WindowInteropHelper(window).Handle;
        if (handle == 0) return;
        int value = dark ? 1 : 0;
        Native.DwmSetWindowAttribute(handle, 20, ref value, sizeof(int));
    }

    /// <summary>Raised on the UI thread when the user switches light/dark mode.</summary>
    public static event Action? Changed;

    static Theme()
    {
        SystemEvents.UserPreferenceChanged += (_, e) =>
        {
            if (e.Category is UserPreferenceCategory.General or UserPreferenceCategory.VisualStyle or UserPreferenceCategory.Color)
                Application.Current?.Dispatcher.BeginInvoke(() => Changed?.Invoke());
        };
    }
}
