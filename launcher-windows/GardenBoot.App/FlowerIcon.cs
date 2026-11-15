using System.Runtime.InteropServices;
using System.Windows;
using System.Windows.Media;
using System.Windows.Media.Imaging;

namespace GardenBoot.App;

/// <summary>The original five-petal mark (launcher-spec/DESIGN.md §5), drawn in code — no image assets or icon libraries.</summary>
internal static class FlowerIcon
{
    /// <summary>The mark in a unit square: five elliptical petals around a hollow centre.</summary>
    public static Geometry Mark()
    {
        Geometry petals = Geometry.Empty;
        for (int i = 0; i < 5; i++)
        {
            var petal = new EllipseGeometry(new Point(0.5, 0.5 - 0.235), 0.145, 0.215) { Transform = new RotateTransform(i * 72, 0.5, 0.5) };
            petals = new CombinedGeometry(GeometryCombineMode.Union, petals, petal);
        }
        var mark = new CombinedGeometry(GeometryCombineMode.Exclude, petals, new EllipseGeometry(new Point(0.5, 0.5), 0.085, 0.085));
        mark.Freeze();
        return mark;
    }

    public static BitmapSource Render(int size, Color color)
    {
        var visual = new DrawingVisual();
        using (var context = visual.RenderOpen())
        {
            var geometry = Mark().Clone();
            geometry.Transform = new ScaleTransform(size, size);
            context.DrawGeometry(new SolidColorBrush(color), null, geometry);
        }
        var bitmap = new RenderTargetBitmap(size, size, 96, 96, PixelFormats.Pbgra32);
        bitmap.Render(visual);
        bitmap.Freeze();
        return bitmap;
    }

    /// <summary>A tray icon: white on a dark taskbar, near-black on a light one. Caller destroys it.</summary>
    public static nint Create(int size, bool darkTaskbar)
    {
        size = Math.Max(16, size);
        var bitmap = Render(size, darkTaskbar ? Colors.White : Color.FromRgb(0x1F, 0x1F, 0x1F));
        var pixels = new byte[size * size * 4];
        bitmap.CopyPixels(pixels, size * 4, 0);
        for (int i = 0; i < pixels.Length; i += 4) // premultiplied → straight alpha for the icon bitmap
        {
            var a = pixels[i + 3];
            if (a is 0 or 255) continue;
            for (int c = 0; c < 3; c++) pixels[i + c] = (byte)Math.Min(255, pixels[i + c] * 255 / a);
        }
        var header = new Native.BitmapInfoHeader
        { Size = (uint)Marshal.SizeOf<Native.BitmapInfoHeader>(), Width = size, Height = -size, Planes = 1, BitCount = 32 };
        var color = Native.CreateDIBSection(0, ref header, 0, out var bits, 0, 0);
        Marshal.Copy(pixels, 0, bits, pixels.Length);
        var mask = Native.CreateBitmap(size, size, 1, 1, new byte[((size + 15) / 16) * 2 * size]);
        var info = new Native.IconInfo { Icon = 1, Mask = mask, Color = color };
        var icon = Native.CreateIconIndirect(ref info);
        Native.DeleteObject(color);
        Native.DeleteObject(mask);
        return icon;
    }
}
