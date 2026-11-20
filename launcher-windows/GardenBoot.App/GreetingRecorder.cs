using System.Globalization;
using System.IO;
using System.Windows;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using GardenBoot.Core;

namespace GardenBoot.App;

/// <summary>
/// Review command (same idea as macOS --render-greeting): draws the built-in Welcome offscreen with RenderTargetBitmap
/// and writes numbered PNG frames, so checking the animation never puts a window on the desktop.
///
///     Sakura.exe --render-greeting OUT_DIR [--greeting-name NAME] [--greeting-size 1280x720] [--greeting-fps 30]
///                [--greeting-length 4.4] [--greeting-exit-at 3.4] [--greeting-still]
/// </summary>
internal static class GreetingRecorder
{
    public static void Record(string[] args)
    {
        string? Value(string flag)
        {
            var i = Array.IndexOf(args, flag);
            return i >= 0 && i + 1 < args.Length ? args[i + 1] : null;
        }
        var output = Path.GetFullPath(args[1]);
        var name = Greeting.NormalizedName(Value("--greeting-name"));
        var still = args.Contains("--greeting-still");
        var size = (Value("--greeting-size") ?? "1280x720").Split('x');
        if (size.Length != 2) throw new ArgumentException("--greeting-size 格式如 1280x720");
        int width = int.Parse(size[0], CultureInfo.InvariantCulture), height = int.Parse(size[1], CultureInfo.InvariantCulture);
        if (width is < 320 or > 3840 || height is < 240 or > 2160) throw new ArgumentException("--greeting-size 超出范围");
        var fps = int.Parse(Value("--greeting-fps") ?? "30", CultureInfo.InvariantCulture);
        var exitAt = double.Parse(Value("--greeting-exit-at") ?? "3.4", CultureInfo.InvariantCulture);
        var length = double.Parse(Value("--greeting-length") ?? (exitAt + 1).ToString(CultureInfo.InvariantCulture), CultureInfo.InvariantCulture);
        Directory.CreateDirectory(output);

        var view = new ScriptGreetingView(name, still, traceNow: true);
        view.Measure(new Size(width, height));
        view.Arrange(new Rect(0, 0, width, height));
        view.UpdateLayout();
        var frames = (int)(length * fps);
        for (var frame = 0; frame < frames; frame++)
        {
            var time = frame / (double)fps;
            view.Render(time, time >= exitAt ? time - exitAt : null);
            view.UpdateLayout();
            var bitmap = new RenderTargetBitmap(width, height, 96, 96, PixelFormats.Pbgra32);
            bitmap.Render(view);
            var encoder = new PngBitmapEncoder();
            encoder.Frames.Add(BitmapFrame.Create(bitmap));
            using var file = File.Create(Path.Combine(output, $"frame_{frame:D4}.png"));
            encoder.Save(file);
        }
        Console.WriteLine($"render-greeting frames={frames} fps={fps} size={width}x{height} face={ScriptArt.FaceName}");
    }
}
