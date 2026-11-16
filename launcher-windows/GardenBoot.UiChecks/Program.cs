using System.IO;
using System.Reflection;
using System.Text.Json;
using System.Windows;
using System.Windows.Automation;
using System.Windows.Controls;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using System.Windows.Threading;
using GardenBoot.Core;

namespace GardenBoot.UiChecks;

/// <summary>Exercises the real window inside its own WPF process; no desktop input injection.</summary>
internal static class Program
{
    private static IEnumerable<T> Controls<T>(DependencyObject node) where T : DependencyObject
    {
        if (node is T found) yield return found;
        foreach (var child in LogicalTreeHelper.GetChildren(node).OfType<DependencyObject>())
            foreach (var item in Controls<T>(child)) yield return item;
    }
    private static void Require(bool ok, string message) { if (!ok) throw new InvalidOperationException(message); }
    private static void Click(Window w, string label) => Controls<Button>(w).Single(b => Equals(b.Content, label) || AutomationProperties.GetName(b) == label).RaiseEvent(new RoutedEventArgs(Button.ClickEvent));
    private static Slider Slider(Window w, string label) => Controls<Slider>(w).Single(s => AutomationProperties.GetName(s) == label);
    private static CheckBox Custom(Slider s) => Controls<CheckBox>((DependencyObject)LogicalTreeHelper.GetParent(LogicalTreeHelper.GetParent(s))).Single();
    private static Window Create(InstalledPack pack, ExperienceSettings settings, Action<ExperienceSettings> save, Action<ExperienceSettings> preview)
    {
        var type = Assembly.Load("Sakura").GetType("GardenBoot.App.ExperienceWindow", true)!;
        return (Window)Activator.CreateInstance(type, pack, settings, "", save, preview)!;
    }
    private static void Render(Window w, string path)
    {
        w.UpdateLayout();
        var content = (FrameworkElement)w.Content;
        var bitmap = new RenderTargetBitmap((int)Math.Ceiling(content.ActualWidth), (int)Math.Ceiling(content.ActualHeight), 96, 96, PixelFormats.Pbgra32);
        var surface = new DrawingVisual();
        using (var drawing = surface.RenderOpen())
        {
            var bounds = new Rect(0, 0, content.ActualWidth, content.ActualHeight);
            drawing.DrawRectangle(w.Background, null, bounds);
            drawing.DrawRectangle(new VisualBrush(content) { ViewboxUnits = BrushMappingMode.Absolute, Viewbox = bounds, Stretch = Stretch.None, AlignmentX = AlignmentX.Left, AlignmentY = AlignmentY.Top }, null, bounds);
        }
        bitmap.Render(surface);
        var encoder = new PngBitmapEncoder(); encoder.Frames.Add(BitmapFrame.Create(bitmap));
        using var file = File.Create(path); encoder.Save(file);
    }
    private static void CheckRealPlayer(string output, string demo, string packId)
    {
        var root = Path.Combine(output, "real-player"); Directory.CreateDirectory(root);
        var document = new ExperienceSettings { MasterVolume = .35 };
        document.Packs[packId] = new() { Overrides = new() { FadeDuration = 1.2, MaxWaitSeconds = 1, LaunchCoverage = .55 } };
        var store = new ExperienceStore(root); store.Save(document); var original = File.ReadAllText(store.Path);
        var start = new System.Diagnostics.ProcessStartInfo(Path.Combine(Path.GetDirectoryName(demo)!, "Sakura.exe"));
        foreach (var arg in new[] { "--test-root", root, "--test-target-exe", Path.Combine(root, "NonexistentTarget.exe"), "--preview" }) start.ArgumentList.Add(arg);
        using var process = System.Diagnostics.Process.Start(start)!;
        try
        {
            string log = ""; var clock = System.Diagnostics.Stopwatch.StartNew(); var captured = false;
            while (clock.Elapsed.TotalSeconds < 12)
            {
                var path = Path.Combine(root, "events.log");
                if (File.Exists(path))
                {
                    using var file = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete);
                    using var reader = new StreamReader(file); log = reader.ReadToEnd();
                }
                if (log.Contains("player-finished reason=")) break;
                if (!captured && log.Contains("player-show") && ProcessWindow(process.Id) is { } shown)
                {
                    System.Threading.Thread.Sleep(250); // past the 0.12 s fade-in
                    CaptureScreen(shown, Path.Combine(output, "real-player-screen.png"));
                    captured = true;
                }
                System.Threading.Thread.Sleep(50);
            }
            Require(log.Contains("player-finished reason=window-timeout"), "Saved wait override must end the real preview: " + log);
            var line = log.Split('\n').Single(l => l.Contains("experience-applied "));
            foreach (var (key, expected) in new[] { ("volume", .28), ("fade", 1.2), ("coverage", .55) })
            {
                var raw = System.Text.RegularExpressions.Regex.Match(line, key + "=([^ ]+)").Groups[1].Value;
                Require(double.TryParse(raw, System.Globalization.NumberStyles.Float, System.Globalization.CultureInfo.InvariantCulture, out var value)
                    && Math.Abs(value - expected) < 1e-9, "Real player must use saved " + key);
            }
            Require(File.ReadAllText(store.Path) == original, "Playback must not rewrite settings");
            Require(log.IndexOf("first-frame", StringComparison.Ordinal) is >= 0 and var first && first < log.IndexOf("player-show", StringComparison.Ordinal),
                    "The overlay is shown only after the first video frame");
            Require(captured, "Captured the visible overlay");
        }
        finally { if (!process.HasExited) { process.Kill(); process.WaitForExit(5000); } }
    }
    private static PlaybackState PlayedAt(double at) { var state = new PlaybackState(); state.Record("default-codex", at, "demo-garden"); return state; }
    private sealed class RecordingActions : App.ILibraryActions
    {
        public List<string> Calls { get; } = [];
        public void SetActive(string id) => Calls.Add("active:" + id);
        public void Remove(InstalledPack pack) => Calls.Add("remove:" + pack.Id);
        public void Import() => Calls.Add("import");
        public void CreateFromVideo() => Calls.Add("create-from-video");
        public void ResetToday() => Calls.Add("reset-today");
        public void TestTarget(string id) => Calls.Add("test:" + id);
    }
    private static T Named<T>(Window w, string name) where T : FrameworkElement => Controls<T>(w).Single(c => AutomationProperties.GetName(c) == name);
    private static void ClickNamed(Window w, string name) => Named<Button>(w, name).RaiseEvent(new RoutedEventArgs(Button.ClickEvent));
    private static void CheckLibrary(string output, string demo, List<string> checks)
    {
        var root = Path.Combine(output, "library"); if (Directory.Exists(root)) Directory.Delete(root, true);
        var packsRoot = Path.Combine(root, "Packs"); Directory.CreateDirectory(packsRoot);
        var demoPack = PackLibrary.Load(demo);
        var second = Path.Combine(root, "src-second"); Directory.CreateDirectory(second);
        foreach (var file in Directory.GetFiles(demo)) File.Copy(file, Path.Combine(second, Path.GetFileName(file)));
        var manifest = PackManifest.Parse(File.ReadAllText(Path.Combine(second, "manifest.json"))) with { Id = "second-garden", Name = "第二个花园", Cover = null };
        File.WriteAllText(Path.Combine(second, "manifest.json"), manifest.ToJson());
        var b = PackLibrary.Load(second);
        var store = new ExperienceStore(root);
        var actions = new RecordingActions();
        (ExperienceSettings Draft, InstalledPack Pack)? previewed = null;
        var now = DateTimeOffset.UtcNow.ToUnixTimeMilliseconds() / 1000.0;
        var view = new App.LibraryView([demoPack, b], new Dictionary<string, string> { ["broken-one"] = "缺少文件" }, demoPack.Id, demoPack.Id,
                                       PlayedAt(now - 5), Path.Combine(root, "Cache"));
        var window = new App.ExperienceWindow(demoPack, new ExperienceSettings(), "", store.Save, (d, p) => previewed = (d.Copy(), p), view, actions);
        try
        {
            window.Show(); window.UpdateLayout();
            Require(Controls<Border>(window).Count(c => AutomationProperties.GetName(c).StartsWith("动画 ")) == 2, "Two library cards");
            Require(Controls<TextBlock>(window).Any(t => t.Text.Contains("broken-one")), "Problems are listed");
            Require(!Named<Button>(window, "移除 demo-garden").IsEnabled && Named<Button>(window, "移除 second-garden").IsEnabled, "Bundled pack cannot be removed");
            Require(!Named<Button>(window, "设为当前 demo-garden").IsEnabled, "Current pack is marked");
            checks.Add("library-cards-problems-and-bundled-guard");
            ClickNamed(window, "收藏 second-garden");
            Named<ComboBox>(window, "轮换方式").SelectedIndex = 2;
            Require(!File.Exists(store.Path), "Favorites and rotation stay in the draft until saved");
            ClickNamed(window, "设为当前 second-garden"); Click(window, "下次启动照常播放");
            Require(actions.Calls.SequenceEqual(["active:second-garden", "reset-today"]), "Immediate actions: " + string.Join(",", actions.Calls));
            Require(!File.Exists(store.Path), "Immediate actions do not save the draft");
            checks.Add("favorite-rotation-in-draft-immediate-actions-separate");
            Controls<RadioButton>(window).Single(r => Equals(r.Content, "每天首次")).IsChecked = true;
            Named<ComboBox>(window, "新的一天开始时间").SelectedIndex = 0;
            Require(Controls<TextBlock>(window).Any(t => t.Text.StartsWith("今天已于")), "Today status shows the last automatic play");
            Named<ComboBox>(window, "新的一天开始时间").SelectedIndex = 5;
            var fade = Slider(window, "淡出时长"); Custom(fade).IsChecked = true; fade.Value = 1.5;
            var card = Controls<Border>(window).Single(c => AutomationProperties.GetName(c) == "动画 second-garden");
            card.RaiseEvent(new System.Windows.Input.MouseButtonEventArgs(System.Windows.Input.Mouse.PrimaryDevice, 0, System.Windows.Input.MouseButton.Left)
                { RoutedEvent = UIElement.MouseLeftButtonUpEvent });
            Require(Controls<TextBlock>(window).Any(t => t.Text == "第二个花园"), "Card click switches the edited pack");
            Require(Custom(Slider(window, "淡出时长")).IsChecked == false, "Second pack shows its own parameters");
            Controls<Border>(window).Single(c => AutomationProperties.GetName(c) == "动画 demo-garden").RaiseEvent(
                new System.Windows.Input.MouseButtonEventArgs(System.Windows.Input.Mouse.PrimaryDevice, 0, System.Windows.Input.MouseButton.Left) { RoutedEvent = UIElement.MouseLeftButtonUpEvent });
            Click(window, "预览当前调整");
            Require(previewed?.Pack.Id == "demo-garden" && Math.Abs(previewed.Value.Draft.Resolve(demoPack.Manifest).EffectiveFadeDuration - 1.5) < 1e-9,
                    "Previewing another card uses the draft for that pack");
            Click(window, "保存设置");
            var saved = store.Load();
            Require(saved.Library.Favorites.SequenceEqual(["second-garden"]) && saved.Library.Rotation == PackRotation.ShuffleFavorites, "Saved library preferences");
            Require(saved.Playback.Frequency == PlayFrequency.FirstOfDay && saved.Playback.DayStartHour == 5, "Saved playback preferences");
            Require(Math.Abs(saved.Packs["demo-garden"].Overrides.FadeDuration!.Value - 1.5) < 1e-9, "Edits to the first pack survive switching");
            checks.Add("switch-pack-keeps-draft-and-saves-v2");
            window.UpdateLibrary(view with { Packs = [demoPack], ActiveId = demoPack.Id });
            Require(Controls<TextBlock>(window).Any(t => t.Text == "花园 · 示例") || Controls<TextBlock>(window).Any(t => t.Text == demoPack.Manifest.Name), "Removed pack falls back");
            Require(Controls<Border>(window).Count(c => AutomationProperties.GetName(c).StartsWith("动画 ")) == 1, "Library refreshes after removal");
            checks.Add("library-refresh-falls-back");
            Render(window, Path.Combine(output, "window-library.png"));
        }
        finally { window.Close(); }
    }
    private static void CheckVideoFit(string output, string demo, List<string> checks)
    {
        var picture = new BitmapImage(); picture.BeginInit(); picture.CacheOption = BitmapCacheOption.OnLoad;
        picture.UriSource = new Uri(Path.Combine(demo, "cover.png")); picture.EndInit();
        var lines = new List<string>();
        foreach (var (name, w, h, mode, expect) in new[] { ("fit-4x3", 800.0, 600.0, VideoFitMode.Auto, "fit"), ("fill-16x10", 800.0, 500.0, VideoFitMode.Auto, "fill"),
                                                           ("forced-fill-4x3", 800.0, 600.0, VideoFitMode.Fill, "fill") })
        {
            lines.Clear();
            var overlay = new App.OverlayWindow(() => { }) { FitMode = mode, Log = lines.Add, Width = w, Height = h, Left = 40, Top = 40 };
            try
            {
                overlay.Show(); overlay.SetImage(picture); overlay.UpdateLayout();
                Require(lines.LastOrDefault() == $"video-fit mode={expect} requested={mode.LogName()}", name + ": " + string.Join(";", lines));
                var file = Path.Combine(output, $"overlay-{name}.png");
                Render(overlay, file);
                // The demo cover has a light square in the middle of the picture; a centred picture keeps it at the centre.
                var decoded = new PngBitmapDecoder(new Uri(file), BitmapCreateOptions.None, BitmapCacheOption.OnLoad).Frames[0];
                var pixel = new byte[4];
                decoded.CopyPixels(new Int32Rect(decoded.PixelWidth / 2, decoded.PixelHeight / 2, 1, 1), pixel, 4, 0);
                Require(pixel[1] > 150, $"{name}: picture must be centred (centre green={pixel[1]})");
            }
            finally { overlay.Close(); }
        }
        checks.Add("overlay-fit-and-fill-rendered");
        var store = new ExperienceStore(Path.Combine(output, "fit-settings"));
        var pack = PackLibrary.Load(demo);
        var window = new App.ExperienceWindow(pack, new ExperienceSettings(), "", store.Save, (_, _) => { }, null, null);
        try
        {
            window.Show(); window.UpdateLayout();
            Named<ComboBox>(window, "贴到窗口时的显示方式").SelectedIndex = 3;
            Click(window, "保存设置");
            Require(store.Load().Packs[pack.Id].Overrides.VideoFit == VideoFitMode.Fit, "Display mode saved as a per-pack override");
            checks.Add("display-mode-saved");
        }
        finally { window.Close(); }
    }
    [System.Runtime.InteropServices.DllImport("user32.dll")] private static extern nint GetDC(nint window);
    [System.Runtime.InteropServices.DllImport("user32.dll")] private static extern int ReleaseDC(nint window, nint dc);
    [System.Runtime.InteropServices.DllImport("gdi32.dll")] private static extern uint GetPixel(nint dc, int x, int y);

    /// <summary>Reads the composed screen, so it shows what the user actually sees through the overlay.</summary>
    private static int ScreenGreen(int x, int y)
    {
        var dc = GetDC(0);
        try { return (int)((GetPixel(dc, x, y) >> 8) & 0xff); } finally { ReleaseDC(0, dc); }
    }
    private static void Pump(int milliseconds)
    {
        var end = Environment.TickCount64 + milliseconds;
        while (Environment.TickCount64 < end)
        {
            // ApplicationIdle runs after everything queued above it, including ContextIdle continuations.
            Dispatcher.CurrentDispatcher.Invoke(DispatcherPriority.ApplicationIdle, new Action(() => { }));
            System.Threading.Thread.Sleep(15);
        }
    }
    [System.Runtime.InteropServices.DllImport("user32.dll")] private static extern bool EnumWindows(EnumProc callback, nint parameter);
    private delegate bool EnumProc(nint window, nint parameter);
    [System.Runtime.InteropServices.DllImport("user32.dll")] private static extern uint GetWindowThreadProcessId(nint window, out uint process);
    [System.Runtime.InteropServices.DllImport("user32.dll")] private static extern bool IsWindowVisible(nint window);
    [System.Runtime.InteropServices.DllImport("gdi32.dll")] private static extern nint CreateCompatibleDC(nint dc);
    [System.Runtime.InteropServices.DllImport("gdi32.dll")] private static extern nint CreateCompatibleBitmap(nint dc, int w, int h);
    [System.Runtime.InteropServices.DllImport("gdi32.dll")] private static extern nint SelectObject(nint dc, nint obj);
    [System.Runtime.InteropServices.DllImport("gdi32.dll")] private static extern bool BitBlt(nint dst, int x, int y, int w, int h, nint src, int sx, int sy, uint rop);
    [System.Runtime.InteropServices.DllImport("gdi32.dll")] private static extern bool DeleteObject(nint obj);
    [System.Runtime.InteropServices.DllImport("gdi32.dll")] private static extern bool DeleteDC(nint dc);

    /// <summary>Largest visible top-level window of a process, in physical pixels.</summary>
    private static RECT? ProcessWindow(int pid)
    {
        RECT? best = null;
        EnumWindows((w, _) =>
        {
            GetWindowThreadProcessId(w, out var owner);
            if (owner == pid && IsWindowVisible(w) && Native_GetWindowRect(w, out var r) && r.Right - r.Left > 200
                && (best is null || (r.Right - r.Left) * (r.Bottom - r.Top) > (best.Value.Right - best.Value.Left) * (best.Value.Bottom - best.Value.Top)))
                best = r;
            return true;
        }, 0);
        return best;
    }

    /// <summary>Saves what is on screen inside a rect (composited), i.e. what the user sees.</summary>
    private static void CaptureScreen(RECT r, string path)
    {
        int w = r.Right - r.Left, h = r.Bottom - r.Top;
        var screen = GetDC(0); var memory = CreateCompatibleDC(screen); var bitmap = CreateCompatibleBitmap(screen, w, h);
        var old = SelectObject(memory, bitmap);
        try
        {
            BitBlt(memory, 0, 0, w, h, screen, r.Left, r.Top, 0x00CC0020);
            SelectObject(memory, old);
            var source = System.Windows.Interop.Imaging.CreateBitmapSourceFromHBitmap(bitmap, 0, Int32Rect.Empty, BitmapSizeOptions.FromEmptyOptions());
            var encoder = new PngBitmapEncoder(); encoder.Frames.Add(BitmapFrame.Create(source));
            using var file = File.Create(path); encoder.Save(file);
        }
        finally { DeleteObject(bitmap); DeleteDC(memory); ReleaseDC(0, screen); }
    }

    private static void CheckOverlayAlpha(string output, List<string> checks)
    {
        var white = new Window { WindowStyle = WindowStyle.None, ResizeMode = ResizeMode.NoResize, Background = Brushes.White, ShowActivated = false,
                                 Topmost = true, Left = 60, Top = 60, Width = 300, Height = 200, ShowInTaskbar = false };
        var overlay = new App.OverlayWindow(() => { });
        try
        {
            white.Show(); Pump(150);
            var helper = new System.Windows.Interop.WindowInteropHelper(white);
            Native_GetWindowRect(helper.Handle, out var r);
            var (x, y) = ((r.Left + r.Right) / 2, (r.Top + r.Bottom) / 2);
            Require(ScreenGreen(x, y) > 220, "white reference window visible");
            overlay.SetFrame(new App.DesktopFrame(new Box(r.Left, r.Top, r.Right - r.Left, r.Bottom - r.Top), 1));
            overlay.ShowHidden(new App.DesktopFrame(new Box(r.Left, r.Top, r.Right - r.Left, r.Bottom - r.Top), 1)); Pump(200);
            var hidden = ScreenGreen(x, y);
            var styleAfterShow = App.Native.GetExStyle(new System.Windows.Interop.WindowInteropHelper(overlay).Handle);
            overlay.SetAlpha(1); Pump(200); var opaque = ScreenGreen(x, y);
            overlay.Opacity = 0.5; Pump(200); var legacyHalf = ScreenGreen(x, y); overlay.Opacity = 1;
            overlay.SetAlpha(0.5); Pump(200); var half = ScreenGreen(x, y);
            File.WriteAllText(Path.Combine(output, "overlay-alpha.json"), JsonSerializer.Serialize(new { hidden, opaque, legacyWindowOpacityHalf = legacyHalf, layeredHalf = half, styleAfterShow = styleAfterShow.ToString("x") }));
            Require(hidden > 220, $"a new overlay must be invisible until revealed (green={hidden})");
            Require(opaque < 40, $"alpha 1 shows the black overlay (green={opaque})");
            Require(half is > 90 and < 170, $"alpha 0.5 blends with what is behind (green={half})");
            checks.Add("overlay-hidden-until-reveal-and-real-alpha-fade");
        }
        finally { overlay.Close(); white.Close(); }
    }
    [System.Runtime.InteropServices.StructLayout(System.Runtime.InteropServices.LayoutKind.Sequential)] private struct RECT { public int Left, Top, Right, Bottom; }
    [System.Runtime.InteropServices.DllImport("user32.dll", EntryPoint = "GetWindowRect")] private static extern bool Native_GetWindowRect(nint window, out RECT rect);
    /// <summary>Design review renders (DESIGN.md §7): settings window light and dark, tray icon at 16 and 32 px.</summary>
    private static void RenderThemes(string output, string demo, List<string> checks)
    {
        var pack = PackLibrary.Load(demo);
        var second = pack with { Manifest = pack.Manifest with { Id = "night-garden", Name = "夜色花园", Cover = null } };
        foreach (var dark in new[] { false, true })
        {
            App.Theme.Override = dark;
            var settings = new ExperienceSettings();
            settings.Library.Favorites.Add(pack.Id);
            var view = new App.LibraryView([pack, second], new Dictionary<string, string>(), pack.Id, pack.Id,
                                           new PlaybackState(), Path.Combine(output, "theme-cache"));
            var window = new App.ExperienceWindow(pack, settings, "", _ => { }, (_, _) => { }, view, new RecordingActions());
            try
            {
                window.Show(); Pump(1500); window.UpdateLayout();
                Require(Controls<TextBlock>(window).Any(t => System.Text.RegularExpressions.Regex.IsMatch(t.Text, @"^当前动画 · \d+ 秒$")), "Hero shows the animation's total duration");
                foreach (var page in dark ? ["animation"] : new[] { "animation", "playback", "sound", "display", "presets" })
                {
                    window.ShowPage(page); Pump(300); window.UpdateLayout();
                    Render(window, Path.Combine(output, $"design-{(dark ? "dark" : "light")}-{page}.png"));
                }
            }
            finally { window.Close(); }
            foreach (var size in new[] { 16, 32 })
            {
                var icon = App.FlowerIcon.Render(size * 4, dark ? Colors.White : Color.FromRgb(0x1F, 0x1F, 0x1F));
                var encoder = new PngBitmapEncoder(); encoder.Frames.Add(BitmapFrame.Create(icon));
                using var file = File.Create(Path.Combine(output, $"tray-{(dark ? "dark" : "light")}-{size}@4x.png")); encoder.Save(file);
            }
            Require(App.FlowerIcon.Create(16, dark) != 0, "tray icon handle");
        }
        App.Theme.Override = null;
        checks.Add("design-renders-light-dark-and-icon");
    }
    private static void CheckTargets(string output, string demo, List<string> checks)
    {
        var root = Path.Combine(output, "targets"); Directory.CreateDirectory(root);
        var pack = PackLibrary.Load(demo);
        var second = pack with { Manifest = pack.Manifest with { Id = "night-garden", Name = "夜色花园", Cover = null } };
        var store = new ExperienceStore(root);
        var view = new App.LibraryView([pack, second], new Dictionary<string, string>(), pack.Id, pack.Id, new PlaybackState(), Path.Combine(root, "Cache"));
        var fake = new List<App.InstalledApp>
        {
            new("Fake Browser", new WindowsTargetIdentity { Path = @"C:\Fake\browser.exe" }, @"C:\Fake\browser.exe", null),
            new("ChatGPT", new WindowsTargetIdentity { Package = "OpenAI.Codex" }, "OpenAI.Codex", null),
        };
        var window = new App.ExperienceWindow(pack, new ExperienceSettings(), "", store.Save, (_, _) => { }, view, new RecordingActions())
        { InstalledAppsProvider = () => Task.FromResult<IReadOnlyList<App.InstalledApp>>(fake) };
        try
        {
            window.Show(); window.ShowPage("targets"); Pump(300); window.UpdateLayout();
            Named<ComboBox>(window, "动画 default-codex").SelectedIndex = 2; // 夜色花园
            Click(window, "\uFF0B  添加应用"); Pump(400);
            var picker = Application.Current.Windows.OfType<App.AppPickerWindow>().Single();
            Require(!Named<Button>(picker, "添加 ChatGPT").IsEnabled, "The default ChatGPT package counts as already added");
            ClickNamed(picker, "添加 Fake Browser"); Pump(100);
            Require(!Named<Button>(picker, "添加 Fake Browser").IsEnabled, "An added app cannot be added twice");
            Render(picker, Path.Combine(output, "design-light-picker.png"));
            picker.Close();
            var added = Controls<CheckBox>(window).Single(c => AutomationProperties.GetName(c).StartsWith("启用 ") && AutomationProperties.GetName(c) != "启用 default-codex");
            added.IsChecked = false; added.RaiseEvent(new RoutedEventArgs(System.Windows.Controls.Primitives.ButtonBase.ClickEvent));
            Render(window, Path.Combine(output, "design-light-targets.png"));
            Require(!File.Exists(store.Path), "Targets are part of the draft");
            Click(window, "保存设置");
            var saved = store.Load();
            Require(saved.Targets.Count == 2 && saved.Targets[0].Animation == "night-garden" && saved.Targets[1].Windows?.Path == @"C:\Fake\browser.exe"
                    && !saved.Targets[1].Enabled && saved.Targets[1].Name == "Fake Browser", "Saved targets: " + string.Join(";", saved.Targets.Select(t => $"{t.Id}/{t.Animation}/{t.Enabled}")));
            ClickNamed(window, "移除应用 " + saved.Targets[1].Id); Click(window, "保存设置");
            Require(store.Load().Targets.Single().Id == "default-codex", "Remove a target");
            checks.Add("targets-page-picker-draft-save-remove");
        }
        finally { window.Close(); }
    }

    private static void CheckInstalledApps(string output, List<string> checks)
    {
        var task = App.InstalledApps.LoadAsync();
        var clock = System.Diagnostics.Stopwatch.StartNew();
        while (!task.IsCompleted && clock.Elapsed.TotalSeconds < 30) Pump(100);
        Require(task.IsCompletedSuccessfully, "Read the Start menu apps: " + (task.Exception?.InnerException?.ToString() ?? "timeout"));
        var apps = task.Result;
        File.WriteAllText(Path.Combine(output, "installed-apps.json"), JsonSerializer.Serialize(new
        {
            count = apps.Count, packaged = apps.Count(a => a.Identity.Package is not null), exe = apps.Count(a => a.Identity.Path is not null),
            withIcon = apps.Count(a => a.Icon is not null), codex = apps.Where(a => a.Identity.Package == "OpenAI.Codex").Select(a => a.Name),
            seconds = Math.Round(clock.Elapsed.TotalSeconds, 2), sample = apps.Take(12).Select(a => a.Name + " | " + a.Detail),
        }, new JsonSerializerOptions { WriteIndented = true, Encoder = System.Text.Encodings.Web.JavaScriptEncoder.UnsafeRelaxedJsonEscaping }));
        Require(apps.Count > 5 && apps.Any(a => a.Identity.Path is not null) && apps.Any(a => a.Identity.Package is not null), "Both desktop and packaged apps listed");
        checks.Add("installed-apps-listed");
    }
    private sealed class OverviewStub : App.IOverviewRuntime
    {
        public bool WelcomeDismissed { get; private set; }
        public App.UpdateOverview UpdateState { get; set; } = new("0.2.0-preview.5", true, false, "尚未检查更新");
        public int UpdateChecks, UpdateDownloads;
        public App.UpdateOverview UpdateOverview() => UpdateState;
        public void CheckForUpdatesFromSettings() { if (!UpdateState.Checking) { UpdateChecks++; UpdateState = UpdateState with { Checking = true }; } }
        public void SetAutomaticUpdates(bool enabled) => UpdateState = UpdateState with { Automatic = enabled };
        public void OpenUpdateDownload() => UpdateDownloads++;
        public bool NoPack { get; set; }
        public List<string> Calls { get; } = [];
        public void SetWelcomeDismissed(bool value) => WelcomeDismissed = value;
        public App.OverviewSnapshot Overview(string? id)
        {
            var chosen = id == "saved-b" ? "saved-b" : "saved-a";
            return new([new("saved-a", "已保存应用 A"), new("saved-b", "已保存应用 B")], chosen,
                PlaybackStatusReason.Resolve(new() { Paused = chosen == "saved-a", PlayedToday = chosen == "saved-b", HasPack = !NoPack }));
        }
        public void PerformOverviewAction(string action) => Calls.Add(action);
    }
    private static void CheckOverview(string output, string demo, List<string> checks)
    {
        Require(App.AppOptions.Parse([]).RequestSettings, "Manual launch opens settings");
        Require(App.AppOptions.Parse(["--settings"]).RequestSettings, "Explicit settings opens settings");
        Require(!App.AppOptions.Parse(["--at-login"]).RequestSettings, "Login launch stays silent, including existing instances");
        Require(!App.AppOptions.Parse(["--preview"]).RequestSettings, "Preview command does not open settings");
        checks.Add("manual-and-explicit-settings-vs-silent-login-presentation");
        var pack = PackLibrary.Load(demo); var runtime = new OverviewStub();
        ExperienceSettings? saved = null, previewed = null;
        var window = new App.ExperienceWindow(pack, new(), "", d => saved = d.Copy(), (d, _) => previewed = d.Copy(),
            new([pack], new Dictionary<string, string>(), pack.Id, pack.Id, new(), Path.Combine(output, "overview-cache")), null, runtime);
        window.InstalledAppsProvider = () => Task.FromResult<IReadOnlyList<App.InstalledApp>>([]);
        try
        {
            window.Show(); window.UpdateLayout(); Pump(100);
            Require(Controls<TextBlock>(window).Any(x => x.Text == "自动播放已暂停"), "Saved pause status is shown");
            Slider(window, "总音量").Value = .29;
            Require(Controls<TextBlock>(window).Any(x => x.Text.Contains("上方状态仍依据已保存设置")), "Draft status is explicit");
            var target = Named<ComboBox>(window, "查看状态的应用");
            Require(target.Items.Count == 2, "Overview uses saved runtime targets");
            target.SelectedValue = "saved-b"; window.UpdateLayout();
            Require(Controls<TextBlock>(window).Any(x => x.Text == "今天已经播放过"), "Daily status is per target");
            ClickNamed(window, "关闭使用引导"); Require(runtime.WelcomeDismissed && saved is null, "Dismissing guide does not save draft");
            ClickNamed(window, "查看使用引导"); Require(!runtime.WelcomeDismissed && saved is null, "Guide can reopen without saving draft");
            var autoUpdate = Named<CheckBox>(window, "自动检查更新");
            Require(autoUpdate.IsChecked == true, "Update switch shows the runtime preference");
            autoUpdate.IsChecked = false;
            Require(!runtime.UpdateState.Automatic && saved is null, "Update switch applies immediately without saving the parameter draft");
            ClickNamed(window, "检查更新");
            Require(runtime.UpdateChecks == 1 && !Named<Button>(window, "检查更新").IsEnabled && saved is null, "Window checks updates once and disables repeated checks without saving the draft");
            runtime.UpdateState = runtime.UpdateState with { Checking = false, Message = "暂时无法检查更新，请稍后再试。" };
            window.ShowPage("overview");
            Require(Named<Button>(window, "检查更新").IsEnabled && Controls<TextBlock>(window).Any(t => t.Text.Contains("暂时无法检查更新")), "Failed checks show an inline message and allow retry");
            runtime.UpdateState = runtime.UpdateState with { AvailableVersion = "0.2.0-preview.6", Message = "发现新版本 0.2.0-preview.6" };
            window.ShowPage("overview"); ClickNamed(window, "下载新版本");
            Require(runtime.UpdateDownloads == 1 && saved is null, "New release download is visible and does not save the draft");
            checks.Add("overview-update-controls-runtime-state-and-draft-isolation");
            ClickNamed(window, "引导 选择应用");
            Require(Controls<RadioButton>(window).Single(x => Equals(x.Content, "应用")).IsChecked == true, "Guide navigates to apps");
            window.ShowPage("overview"); ClickNamed(window, "引导 选择动画");
            Require(Controls<RadioButton>(window).Single(x => Equals(x.Content, "动画")).IsChecked == true, "Guide navigates to animations");
            window.ShowPage("overview"); ClickNamed(window, "引导 预览");
            Require(previewed?.MasterVolume == .29 && saved is null, "Guide preview uses draft, does not save or launch target");
            Render(window, Path.Combine(output, "overview-light.png"));
            window.Width = 820; window.Height = 560; window.UpdateLayout(); Render(window, Path.Combine(output, "overview-compact.png"));
            Click(window, "保存设置"); Require(saved?.MasterVolume == .29, "Only explicit save persists draft");
            checks.Add("overview-per-target-saved-state-guide-and-draft-actions");
        }
        finally { window.Close(); }
        var empty = new App.ExperienceWindow(null, new(), "", _ => { }, (_, _) => throw new InvalidOperationException("No-pack preview invoked"),
            new([], new Dictionary<string, string>(), null, "demo-garden", new(), ""), null, null);
        try
        {
            empty.Show(); empty.UpdateLayout();
            typeof(App.ExperienceWindow).GetMethod("TryPreview", BindingFlags.Instance | BindingFlags.NonPublic)!.Invoke(empty, null);
            Require(Controls<TextBlock>(empty).Any(x => x.Text.Contains("请先导入可用动画包")), "Empty library offers recovery without a fake pack");
            Click(empty, "保存设置");
            checks.Add("overview-empty-library-settings-and-preview-recovery");
        }
        finally { empty.Close(); }
        var folder = Path.Combine(output, "welcome-prefs"); Directory.CreateDirectory(folder);
        File.WriteAllText(Path.Combine(folder, "settings.json"), "{\"ActivePackId\":\"demo-garden\",\"Paused\":true}");
        var preferences = App.Settings.Load(folder, new EventLog(folder));
        Require(!preferences.WelcomeDismissed && preferences.Paused, "Legacy local preferences still load");
        preferences.WelcomeDismissed = true; preferences.Save(folder);
        var reloaded = App.Settings.Load(folder, new EventLog(folder));
        Require(reloaded.WelcomeDismissed && reloaded.Paused && reloaded.ActivePackId == "demo-garden", "Welcome dismissal preserves existing preferences");
        checks.Add("welcome-preference-backward-compatible");
    }
    [STAThread] private static int Main(string[] args)
    {
        if (args.Length != 2 || !Path.IsPathFullyQualified(args[0]) || !Path.IsPathFullyQualified(args[1])) return 2;
        var output = args[0]; Directory.CreateDirectory(output);
        var app = new Application { ShutdownMode = ShutdownMode.OnExplicitShutdown };
        int code = 1;
        Window? window = null;
        app.Startup += (_, _) => app.Dispatcher.BeginInvoke(DispatcherPriority.ContextIdle, new Action(() =>
        {
            var checks = new List<string>();
            try
            {
                Require(Environment.UserInteractive && System.Diagnostics.Process.GetCurrentProcess().SessionId != 0, "Requires logged-in desktop");
                var pack = PackLibrary.Load(args[1]);
                var store = new ExperienceStore(output);
                ExperienceSettings? previewed = null;
                window = Create(pack, new(), store.Save, d => previewed = d.Copy()); window.Show(); window.UpdateLayout();
                Slider(window, "总音量").Value = .35;
                var fade = Slider(window, "淡出时长"); Custom(fade).IsChecked = true; fade.Value = 1.2;
                var coverage = Slider(window, "开场尺寸"); Custom(coverage).IsChecked = true; coverage.Value = .55;
                Click(window, "预览当前调整");
                Require(previewed?.MasterVolume == .35 && Math.Abs(previewed.Resolve(pack.Manifest).EffectiveFadeDuration - 1.2) < 1e-9, "Preview must consume draft");
                Require(!File.Exists(store.Path), "Preview must not write disk"); checks.Add("draft-preview-does-not-save");
                Controls<TextBox>(window).Single(t => AutomationProperties.GetName(t) == "方案名称").Text = "轻柔测试";
                Click(window, "存为方案"); Click(window, "保存设置");
                var saved = store.Load();
                Require(saved.MasterVolume == .35 && saved.Packs[pack.Id].Presets.Single().Name == "轻柔测试", "Save document and preset");
                checks.Add("save-settings-and-named-preset"); Render(window, Path.Combine(output, "window-top.png"));
                window.Close();
                window = Create(pack, store.Load(), store.Save, _ => { }); window.Show(); window.UpdateLayout();
                Require(Slider(window, "总音量").Value == .35 && Math.Abs(Slider(window, "淡出时长").Value - 1.2) < 1e-9, "Reload persisted controls");
                checks.Add("reopen-restores-settings");
                var before = File.ReadAllText(store.Path);
                Controls<CheckBox>(window).Single(c => AutomationProperties.GetName(c) == "自定义淡出起点").IsChecked = true;
                Controls<TextBox>(window).Single(t => AutomationProperties.GetName(t) == "淡出起点秒数").Text = "-2";
                Click(window, "保存设置");
                Require(File.ReadAllText(store.Path) == before && Controls<TextBlock>(window).Any(t => t.Text.StartsWith("未保存：")), "Invalid input must not save");
                checks.Add("invalid-save-preserves-disk");
                Click(window, "恢复本包默认参数"); Click(window, "保存设置");
                Require(store.Load().Packs[pack.Id].Overrides.FadeDuration is null && store.Load().Packs[pack.Id].Presets.Count == 1, "Reset must keep presets");
                checks.Add("reset-keeps-preset");
                var select = Controls<ComboBox>(window).Single(c => c.DisplayMemberPath == "Name"); select.SelectedIndex = 0;
                Click(window, "应用"); Click(window, "保存设置");
                Require(Math.Abs(store.Load().Packs[pack.Id].Overrides.FadeDuration!.Value - 1.2) < 1e-9, "Apply preset restores captured parameters");
                checks.Add("apply-preset-snapshot");
                Controls<ScrollViewer>(window).Single(v => Equals(v.Tag, "content")).ScrollToBottom(); window.UpdateLayout(); Render(window, Path.Combine(output, "window-bottom.png"));
                RenderThemes(output, args[1], checks);
                window.Close(); window = null;
                CheckLibrary(output, args[1], checks);
                CheckVideoFit(output, args[1], checks);
                CheckOverlayAlpha(output, checks);
                CheckTargets(output, args[1], checks);
                CheckInstalledApps(output, checks);
                CheckOverview(output, args[1], checks);
                CheckRealPlayer(output, args[1], pack.Id); checks.Add("saved-profile-drives-real-player-and-timeout");
                File.WriteAllText(Path.Combine(output, "report.json"), JsonSerializer.Serialize(new { passed = true, checks, sessionId = System.Diagnostics.Process.GetCurrentProcess().SessionId }));
                code = 0;
            }
            catch (Exception e)
            {
                File.WriteAllText(Path.Combine(output, "report.json"), JsonSerializer.Serialize(new { passed = false, checks, error = e.ToString() }));
            }
            finally { app.Shutdown(); }
        }));
        app.Run(); return code;
    }
}
