using System.IO;
using System.Text.Json;
using GardenBoot.Core;
using Microsoft.Win32;

namespace GardenBoot.App;

internal sealed class Settings
{
    public Settings() { }
    public string? ActivePackId { get; set; }
    public bool Paused { get; set; }
    public bool WelcomeDismissed { get; set; }
    public bool PlayDespiteReduceMotion { get; set; }
    /// <summary>Featured built-in packs already offered once; a removed one is not reinstalled.</summary>
    public List<string> FeaturedInstalled { get; set; } = [];

    public static Settings Load(string root, EventLog log)
    {
        var path = Path.Combine(root, "settings.json");
        try { return JsonSerializer.Deserialize<Settings>(File.ReadAllText(path)) ?? new(); }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException or JsonException)
        {
            if (File.Exists(path)) log.Write("settings-load-failed");
            return new();
        }
    }

    public void Save(string root)
    {
        Directory.CreateDirectory(root);
        var path = Path.Combine(root, "settings.json");
        File.WriteAllText(path + ".tmp", JsonSerializer.Serialize(this, new JsonSerializerOptions { WriteIndented = true }));
        File.Move(path + ".tmp", path, overwrite: true);
    }
}

internal static class LoginStartup
{
    private const string Key = @"Software\Microsoft\Windows\CurrentVersion\Run";
    private const string Name = "Sakura";
    private static string Command => $"\"{Environment.ProcessPath}\" --at-login";

    public static bool IsEnabled()
    {
        using var key = Registry.CurrentUser.OpenSubKey(Key);
        return string.Equals(key?.GetValue(Name) as string, Command, StringComparison.OrdinalIgnoreCase);
    }

    // Called only by an explicit tray-menu click, never at startup or from a command-line switch.
    public static void SetEnabled(bool enabled)
    {
        var executable = Environment.ProcessPath ?? throw new IOException("无法确定应用路径");
        if (Path.GetFileNameWithoutExtension(executable).Equals("dotnet", StringComparison.OrdinalIgnoreCase))
            throw new IOException("请使用 Sakura.exe 设置开机自动运行");
        using var key = Registry.CurrentUser.CreateSubKey(Key);
        if (enabled) key.SetValue(Name, Command, RegistryValueKind.String);
        else key.DeleteValue(Name, throwOnMissingValue: false);
    }
}
