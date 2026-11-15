using System.Globalization;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Threading;

// Only the integration-test target. It does not start or interact with ChatGPT.
internal static class Program
{
    [STAThread]
    private static void Main(string[] args)
    {
        var app = new Application { ShutdownMode = ShutdownMode.OnExplicitShutdown };
        app.Startup += async (_, _) =>
        {
            if (args.Length >= 2 && args[0] == "--window-delay")
            {
                await Task.Delay(TimeSpan.FromSeconds(double.Parse(args[1], CultureInfo.InvariantCulture)));
                var size = args.SkipWhile(a => a != "--size").Skip(1).FirstOrDefault()?.Split('x');
                var window = new Window
                {
                    Title = "GardenBoot controlled test target",
                    Width = size is { Length: 2 } ? double.Parse(size[0], CultureInfo.InvariantCulture) : 800,
                    Height = size is { Length: 2 } ? double.Parse(size[1], CultureInfo.InvariantCulture) : 500,
                    Left = 180, Top = 180, ShowActivated = false,
                    Content = new TextBlock { Text = "Controlled test window; not ChatGPT", FontSize = 24,
                                              Margin = new Thickness(30) },
                };
                app.MainWindow = window;
                window.Show();
                double? Arg(string name) => args.SkipWhile(a => a != name).Skip(1).FirstOrDefault() is { } v ? double.Parse(v, CultureInfo.InvariantCulture) : null;
                // Simulate a tray app (hide the window, later show it again) or a minimize/restore, for "reappear" checks.
                if (Arg("--hide-after") is { } hideAfter)
                {
                    await Task.Delay(TimeSpan.FromSeconds(hideAfter)); window.Hide();
                    await Task.Delay(TimeSpan.FromSeconds(Arg("--show-after") ?? 3)); window.Show();
                }
                if (Arg("--minimize-after") is { } minimizeAfter)
                {
                    await Task.Delay(TimeSpan.FromSeconds(minimizeAfter)); window.WindowState = WindowState.Minimized;
                    await Task.Delay(TimeSpan.FromSeconds(Arg("--restore-after") ?? 3)); window.WindowState = WindowState.Normal;
                }
                if (args.Contains("--move"))
                {
                    var after = args.SkipWhile(a => a != "--move-after").Skip(1).FirstOrDefault();
                    await Task.Delay(TimeSpan.FromSeconds(after is null ? 1.4 : double.Parse(after, CultureInfo.InvariantCulture)));
                    window.Left += 120;
                    window.Width += 80;
                }
            }
        };
        var expiry = new DispatcherTimer { Interval = TimeSpan.FromSeconds(100) };
        expiry.Tick += (_, _) => app.Shutdown();
        expiry.Start();
        app.Run();
    }
}
