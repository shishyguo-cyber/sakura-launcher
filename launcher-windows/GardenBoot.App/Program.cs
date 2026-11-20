using GardenBoot.Core;
using System.IO;
using System.Security.Cryptography;
using System.Text;
using System.Windows;

namespace GardenBoot.App;

internal static class Program
{
    [STAThread]
    private static int Main(string[] args)
    {
        if (args.Length == 2 && args[0] == "--apply-update")
        {
            try { GardenBoot.Core.SignedUpdate.Apply(args[1]); return 0; }
            catch (SignedUpdate.RecoveryRequired e) {
                if (MessageBox.Show(e.Message, "更新失败", MessageBoxButton.YesNo, MessageBoxImage.Error) == MessageBoxResult.Yes)
                    System.Diagnostics.Process.Start(new System.Diagnostics.ProcessStartInfo("https://github.com/shishyguo-cyber/sakura-launcher/releases") { UseShellExecute = true });
                return 1;
            }
            catch { return 1; }
        }
        // Review command: renders the built-in Welcome offscreen to PNG frames; never opens a window.
        if (args.Length >= 2 && args[0] == "--render-greeting")
        {
            try { GreetingRecorder.Record(args); return 0; }
            catch (Exception e) when (e is ArgumentException or FormatException or IOException or ExperienceException)
            { Console.Error.WriteLine("render-greeting: " + e.Message); return 2; }
        }
        AppOptions options;
        try { options = AppOptions.Parse(args); }
        catch (ArgumentException e)
        {
            MessageBox.Show(e.Message, "Sakura", MessageBoxButton.OK, MessageBoxImage.Error);
            return 2;
        }
        // Test instances are isolated from the user's ordinary launcher and from one another.
        var suffix = options.TestRoot is null ? "" : "." + Convert.ToHexString(
            SHA256.HashData(Encoding.UTF8.GetBytes(options.DataRoot.ToUpperInvariant())))[..16];
        using var single = new Mutex(true, @"Local\GardenBoot.App" + suffix, out var first);
        // Double-clicking Sakura while it already runs: ask the running copy to show its settings, then leave.
        using var show = new EventWaitHandle(false, EventResetMode.AutoReset, @"Local\GardenBoot.App.Show" + suffix);
        if (!first)
        {
            if (options.RequestSettings)
            {
                Native.AllowSetForegroundWindow(-1); // a manual reopen may bring the existing settings forward
                show.Set();
            }
            return 0;
        }
        var app = new Application { ShutdownMode = ShutdownMode.OnExplicitShutdown };
        ApplicationController? controller = null;
        RegisteredWaitHandle? waiter = null;
        app.Startup += (_, _) =>
        {
            controller = new ApplicationController(options);
            controller.Start();
            waiter = ThreadPool.RegisterWaitForSingleObject(show, (_, _) =>
                app.Dispatcher.BeginInvoke(() => controller?.ShowSettings()), null, Timeout.Infinite, executeOnlyOnce: false);
        };
        app.Exit += (_, _) => { waiter?.Unregister(null); controller?.Dispose(); };
        try { return app.Run(); }
        finally { single.ReleaseMutex(); }
    }
}

internal sealed record AppOptions(string DataRoot, string? TestRoot, string? TestTargetExe, bool AtLogin, bool Preview, bool OpenSettings)
{
    /// <summary>Started by hand (no arguments at all): show the settings so the user sees Sakura opened.</summary>
    public bool ManualLaunch { get; init; }
    public string? UpdateReady { get; init; }
    public bool UpdateFailed { get; init; }
    /// <summary>Test hooks: watch the test target for reappearing windows; pretend the system is in this quiet state.</summary>
    public bool TestReappear { get; init; }
    public QuietState? TestQuiet { get; init; }
    /// <summary>Test hook: start "测试一下" for this target id at startup, with a shorter window.</summary>
    public string? TestCompat { get; init; }
    /// <summary>Isolated checks: also install the featured pack (normally skipped under --test-root).</summary>
    public bool TestFeatured { get; init; }
    /// <summary>Isolated checks: check for updates right away (0.5 s) instead of after 60 s.</summary>
    public bool TestCheckUpdate { get; init; }
    /// <summary>Isolated checks: read the release list from this local JSON file; never go online.</summary>
    public string? TestUpdateFeed { get; init; }
    /// <summary>Isolated checks: create a pack from this video with its default name (no dialogs).</summary>
    public string? TestCreateVideo { get; init; }
    public double? TestCompatSeconds { get; init; }
    public bool RequestSettings => OpenSettings || (ManualLaunch && !AtLogin);
    public static AppOptions Parse(string[] args)
    {
        string? root = null, target = null, updateReady = null; bool updateFailed = false;
        bool login = false, preview = false, openSettings = false, testReappear = false, testFeatured = false, testCheckUpdate = false;
        QuietState? testQuiet = null;
        string? testCompat = null, testCreateVideo = null, testUpdateFeed = null; double? testCompatSeconds = null;
        for (int i = 0; i < args.Length; i++)
        {
            switch (args[i])
            {
                case "--test-root": root = FullPath(Value(args, ref i)); break;
                case "--test-target-exe": target = FullPath(Value(args, ref i)); break;
                case "--at-login": login = true; break;
                case "--preview": preview = true; break;
                case "--update-ready": updateReady = FullPath(Value(args, ref i)); break;
                case "--update-failed": updateFailed = true; break;
                case "--settings": openSettings = true; break;
                case "--test-reappear": testReappear = true; break;
                case "--test-featured": testFeatured = true; break;
                case "--test-check-update": testCheckUpdate = true; break;
                case "--test-update-feed": testUpdateFeed = FullPath(Value(args, ref i)); break;
                case "--test-compat": testCompat = Value(args, ref i); break;
                case "--test-create-video": testCreateVideo = FullPath(Value(args, ref i)); break;
                case "--test-compat-seconds": testCompatSeconds = double.Parse(Value(args, ref i), System.Globalization.CultureInfo.InvariantCulture); break;
                case "--test-quiet": testQuiet = Value(args, ref i) switch
                {
                    "fullscreen" => QuietState.Fullscreen, "game" => QuietState.Game, "presentation" => QuietState.Presentation, "normal" => QuietState.Normal,
                    var other => throw new ArgumentException($"未知安静状态：{other}"),
                }; break;
                default: throw new ArgumentException($"未知参数：{args[i]}");
            }
        }
        return new(root ?? Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "GardenBoot"),
                   root, target, login, preview, openSettings) { ManualLaunch = args.Length == 0, UpdateReady = updateReady, UpdateFailed = updateFailed, TestReappear = testReappear, TestQuiet = testQuiet, TestCompat = testCompat, TestCompatSeconds = testCompatSeconds, TestCreateVideo = testCreateVideo, TestFeatured = testFeatured, TestCheckUpdate = testCheckUpdate, TestUpdateFeed = testUpdateFeed };
    }

    private static string Value(string[] args, ref int i) => ++i < args.Length ? args[i] : throw new ArgumentException("参数缺少路径");
    private static string FullPath(string path) => Path.IsPathFullyQualified(path)
        ? Path.TrimEndingDirectorySeparator(Path.GetFullPath(path)) : throw new ArgumentException("测试路径必须是完整路径");
}
