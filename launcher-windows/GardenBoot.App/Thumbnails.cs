using System.IO;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using GardenBoot.Core;

namespace GardenBoot.App;

/// <summary>Cover images and first-frame thumbnails for library cards. Thumbnails live only in the cache folder.</summary>
internal static class PackThumbnails
{
    private const int Width = 320;

    public static async Task Fill(Border target, InstalledPack pack, string cacheRoot)
    {
        try
        {
            if (await Load(pack, cacheRoot) is { } source)
                target.Child = new Image { Source = source, Stretch = Stretch.UniformToFill,
                    HorizontalAlignment = HorizontalAlignment.Center, VerticalAlignment = VerticalAlignment.Center };
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException or NotSupportedException
                                   or InvalidOperationException or TimeoutException or ArgumentException) { }
    }

    private static async Task<ImageSource?> Load(InstalledPack pack, string cacheRoot)
    {
        if (pack.CoverPath is { } cover) return Decode(cover);
        var first = pack.Layout.Intro ?? pack.Layout.Loop ?? pack.Layout.Final;
        var video = pack.PathFor(first);
        var stamp = File.GetLastWriteTimeUtc(video).Ticks;
        var folder = Path.Combine(cacheRoot, "thumbs");
        var cached = Path.Combine(folder, $"{pack.Id}-{stamp}.png");
        if (File.Exists(cached)) return Decode(cached);
        var frame = await FirstFrame(video);
        if (frame is null) return null;
        Directory.CreateDirectory(folder);
        foreach (var old in Directory.EnumerateFiles(folder, pack.Id + "-*.png")) { try { File.Delete(old); } catch (IOException) { } }
        var encoder = new PngBitmapEncoder(); encoder.Frames.Add(BitmapFrame.Create(frame));
        var temporary = cached + ".tmp";
        using (var file = File.Create(temporary)) encoder.Save(file);
        File.Move(temporary, cached, true);
        return frame;
    }

    /// <summary>Decodes an image file into memory so the file is not kept open.</summary>
    public static BitmapSource Decode(string path)
    {
        var image = new BitmapImage();
        image.BeginInit();
        image.CacheOption = BitmapCacheOption.OnLoad;
        image.DecodePixelWidth = Width;
        image.UriSource = new Uri(path);
        image.EndInit();
        image.Freeze();
        return image;
    }

    /// <summary>True when the file decodes as an image (used by pack import).</summary>
    public static bool CanDecode(string path)
    {
        try
        {
            using var stream = File.OpenRead(path);
            var decoder = BitmapDecoder.Create(stream, BitmapCreateOptions.PreservePixelFormat, BitmapCacheOption.OnLoad);
            return decoder.Frames.Count > 0 && decoder.Frames[0].PixelWidth > 0 && decoder.Frames[0].PixelHeight > 0;
        }
        catch (Exception e) when (e is IOException or NotSupportedException or FileFormatException or ArgumentException
                                   or InvalidOperationException or UnauthorizedAccessException) { return false; }
    }

    /// <summary>Renders the first frame within two seconds, else null (the card keeps its placeholder).</summary>
    private static async Task<BitmapSource?> FirstFrame(string video)
    {
        var player = new MediaPlayer { IsMuted = true, ScrubbingEnabled = true };
        var opened = new TaskCompletionSource<bool>();
        player.MediaOpened += (_, _) => opened.TrySetResult(true);
        player.MediaFailed += (_, _) => opened.TrySetResult(false);
        try
        {
            player.Open(new Uri(video));
            var finished = await Task.WhenAny(opened.Task, Task.Delay(2000));
            if (finished != opened.Task || !opened.Task.Result || player.NaturalVideoWidth <= 0) return null;
            player.Play(); player.Pause();
            player.Position = TimeSpan.FromMilliseconds(100);
            await Task.Delay(350);
            var height = (int)Math.Round(Width * player.NaturalVideoHeight / (double)player.NaturalVideoWidth);
            if (height <= 0) return null;
            var visual = new DrawingVisual();
            using (var context = visual.RenderOpen()) context.DrawVideo(player, new Rect(0, 0, Width, height));
            var bitmap = new RenderTargetBitmap(Width, height, 96, 96, PixelFormats.Pbgra32);
            bitmap.Render(visual);
            bitmap.Freeze();
            return bitmap;
        }
        finally { player.Close(); }
    }
}
