using System.Globalization;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;
using System.Windows.Media.Effects;
using System.Windows.Media.Imaging;
using System.Windows.Shapes;
using GardenBoot.Core;

namespace GardenBoot.App;

/// <summary>
/// The built-in "Welcome · 彩虹手写": "welcome &lt;nickname&gt;" written out in one rainbow neon line on black.
/// Pen strokes come from the skeleton of a handwriting face (GardenBoot.Core.ScriptSkeleton), so any nickname can be
/// written. Same look and timing as macOS (ScriptGreetingView.swift).
/// </summary>
internal sealed class ScriptGreetingView : Grid
{
    /// <summary>Red → orange → yellow → green → cyan → blue → violet → pink; blue and violet lifted so the line reads evenly.</summary>
    private static readonly Color[] Rainbow =
    [
        Color.FromRgb(255, 66, 87), Color.FromRgb(255, 143, 46), Color.FromRgb(255, 222, 66), Color.FromRgb(97, 255, 107),
        Color.FromRgb(61, 237, 255), Color.FromRgb(107, 163, 255), Color.FromRgb(179, 120, 255), Color.FromRgb(255, 107, 214),
    ];
    private const double WriteStart = 0.15;

    private readonly bool still;
    private readonly Canvas lettering = new() { HorizontalAlignment = HorizontalAlignment.Center, VerticalAlignment = VerticalAlignment.Center };
    private readonly Path haze = Stroke(), bloom = Stroke(), tube = Stroke(), core = Stroke();
    private readonly Ellipse nib = new() { Opacity = 0, IsHitTestVisible = false };
    private readonly TextBlock? plain;
    private readonly Viewbox? plainBox;
    private ScriptArt? art;
    private double? readyAt;

    /// <summary>True once the pen strokes have been traced (they are built off the UI thread).</summary>
    public bool IsReady => art is not null || plain is not null;

    /// <param name="traceNow">Trace on the calling thread (the offscreen recorder has no running dispatcher).</param>
    public ScriptGreetingView(string? name, bool still, bool traceNow = false)
    {
        this.still = still;
        Background = Brushes.Black;
        IsHitTestVisible = false;
        ClipToBounds = true;
        if (!Greeting.ScriptCanWrite(name))
        {
            // Emoji have no pen strokes to trace: show the line in rainbow lettering and fade it in.
            plain = new TextBlock
            {
                Text = Greeting.ScriptText(name), FontSize = 72, Opacity = 0,
                FontFamily = new FontFamily(ScriptArt.FaceName + ", Segoe UI Emoji, Microsoft YaHei UI"),
                Foreground = RainbowBrush(new Point(0, 0), new Point(1, 0), BrushMappingMode.RelativeToBoundingBox),
                HorizontalAlignment = HorizontalAlignment.Center, VerticalAlignment = VerticalAlignment.Center,
                Effect = new DropShadowEffect { Color = Colors.White, BlurRadius = 18, ShadowDepth = 0, Opacity = .55 },
            };
            // Scales with the overlay like the written line does.
            plainBox = new Viewbox { Child = plain, Stretch = Stretch.Uniform, HorizontalAlignment = HorizontalAlignment.Center, VerticalAlignment = VerticalAlignment.Center };
            Children.Add(plainBox);
            SizeChanged += (_, _) => Fit();
            return;
        }
        foreach (var path in new[] { haze, bloom, tube, core }) lettering.Children.Add(path);
        lettering.Children.Add(nib);
        lettering.Opacity = 0;
        Children.Add(lettering);
        SizeChanged += (_, _) => Fit();
        var raster = ScriptArt.Rasterize(Greeting.ScriptText(name));
        if (traceNow) { Install(ScriptArt.Trace(raster)); return; }
        _ = Task.Run(() => ScriptArt.Trace(raster)).ContinueWith(t => { if (t.IsCompletedSuccessfully) Install(t.Result); },
            CancellationToken.None, TaskContinuationOptions.None, TaskScheduler.FromCurrentSynchronizationContext());
    }

    private static Path Stroke() => new()
    {
        StrokeStartLineCap = PenLineCap.Round, StrokeEndLineCap = PenLineCap.Round, StrokeLineJoin = PenLineJoin.Round,
        IsHitTestVisible = false, SnapsToDevicePixels = false,
    };

    private static LinearGradientBrush RainbowBrush(Point start, Point end, BrushMappingMode mode)
    {
        var brush = new LinearGradientBrush { StartPoint = start, EndPoint = end, MappingMode = mode };
        for (var i = 0; i < Rainbow.Length; i++) brush.GradientStops.Add(new GradientStop(Rainbow[i], i / (double)(Rainbow.Length - 1)));
        brush.Freeze();
        return brush;
    }

    private void Install(ScriptArt traced)
    {
        art = traced;
        lettering.Width = traced.Width;
        lettering.Height = traced.Height;
        var rainbow = RainbowBrush(new Point(traced.Pad, 0), new Point(traced.Width - traced.Pad, 0), BrushMappingMode.Absolute);
        var width = traced.LineWidth;
        foreach (var (path, scale) in new[] { (haze, 2.6), (bloom, 1.5), (tube, 1.0) }) { path.Stroke = rainbow; path.StrokeThickness = width * scale; }
        core.Stroke = new SolidColorBrush(Color.FromArgb(97, 255, 255, 255));
        core.StrokeThickness = width * .28;
        haze.Effect = new BlurEffect { Radius = width * 4.4, KernelType = KernelType.Gaussian };
        bloom.Effect = new BlurEffect { Radius = width * 1.5, KernelType = KernelType.Gaussian };
        haze.Opacity = .55;
        bloom.Opacity = .9;
        var glow = new RadialGradientBrush(Colors.White, Color.FromArgb(0, 255, 255, 255));
        glow.GradientStops.Insert(1, new GradientStop(Color.FromArgb(150, 255, 255, 255), .35));
        glow.Freeze();
        nib.Fill = glow;
        nib.Width = nib.Height = width * 4;
        Fit();
    }

    private void Fit()
    {
        if (plainBox is not null) { plainBox.Width = ActualWidth * .70; plainBox.MaxHeight = ActualHeight * .40; return; }
        if (art is null || ActualWidth <= 0 || ActualHeight <= 0) return;
        var scale = Math.Min(ActualWidth * .80 / art.Width, ActualHeight * .40 / art.Height);
        lettering.LayoutTransform = new ScaleTransform(scale, scale);
    }

    /// <summary>Called every frame by the launch overlay. <paramref name="exit"/> = seconds since the hand-off began.</summary>
    public void Render(double time, double? exit)
    {
        var leaving = Ease((exit ?? 0) / .8);
        if (plain is not null)
        {
            plain.Opacity = Ease(time / .5) * (1 - .6 * leaving);
            return;
        }
        if (art is not { } a) return;
        readyAt ??= time;
        var t = time - readyAt.Value;
        if (still)
        {
            SetProgress(a, 1);
            lettering.Opacity = Ease(t / .5) * (1 - .6 * leaving);
            return;
        }
        lettering.Opacity = Ease(t / .12) * (1 - .6 * leaving);
        var progress = (t - WriteStart) / a.WriteDuration;
        // A touch slower into the first letter, then an even, flowing hand.
        var travel = .2 * Ease(progress) + .8 * Math.Clamp(progress, 0, 1);
        SetProgress(a, travel);
        var settled = Math.Max(0, progress - 1) * a.WriteDuration;
        var breathe = 1 + .12 * Math.Sin(settled * 5) * Ease(settled * 3);
        var flare = Math.Sin(Math.PI * Math.Min(1, (exit ?? 0) / .5)) * .35;
        haze.Opacity = .55 * breathe + flare;
        bloom.Opacity = Math.Min(1, .9 * breathe + flare);
    }

    private double lastTravel = -1;

    private void SetProgress(ScriptArt a, double travel)
    {
        if (Math.Abs(travel - lastTravel) < 1e-6) return;
        lastTravel = travel;
        var (geometry, tip) = a.Pen(travel);
        foreach (var path in new[] { haze, bloom, tube, core }) path.Data = geometry;
        if (tip is { } p && travel is > 0 and < 1)
        {
            Canvas.SetLeft(nib, p.X - nib.Width / 2);
            Canvas.SetTop(nib, p.Y - nib.Height / 2);
            nib.Opacity = .95;
        }
        else nib.Opacity = 0;
    }

    private static double Ease(double t) { var x = Math.Clamp(t, 0, 1); return x * x * (3 - 2 * x); }
}

/// <summary>Pen strokes for one line of handwriting, in a y-down box ready for WPF.</summary>
internal sealed class ScriptArt
{
    private const double TypeSize = 150, Slant = .20, Tracking = -.04;
    /// <summary>Bradley Hand (with Office) matches macOS; Segoe Script ships with every Windows.</summary>
    internal static readonly string FaceName = new[] { "Bradley Hand ITC", "Segoe Script", "Ink Free" }
        .FirstOrDefault(n => Fonts.SystemFontFamilies.Any(f => string.Equals(f.Source, n, StringComparison.OrdinalIgnoreCase))) ?? "Segoe Script";

    public required double Width { get; init; }
    public required double Height { get; init; }
    public required double Pad { get; init; }
    public required double LineWidth { get; init; }
    public required double WriteDuration { get; init; }
    public required List<List<PenPoint>> Strokes { get; init; }
    private double inkLength, liftCost;

    internal sealed record Raster(byte[] Mask, int Width, int Height, int Pad, int Characters);

    /// <summary>Draws the text white on transparent (UI thread) and keeps its alpha as coverage.</summary>
    public static Raster Rasterize(string text)
    {
        // CJK and other scripts fall back to a system face that has the glyphs; the skeleton still writes them.
        var typeface = new Typeface(new FontFamily(FaceName + ", Microsoft YaHei UI, SimSun"), FontStyles.Normal, FontWeights.Normal, FontStretches.Normal);
        var elements = new List<(FormattedText Text, double X)>();
        var pad = (int)(36 + Slant * TypeSize * .8);
        double x = pad, lineHeight = 0, baseline = 0;
        var e = StringInfo.GetTextElementEnumerator(text);
        var count = 0;
        while (e.MoveNext())
        {
            var formatted = new FormattedText(e.GetTextElement(), CultureInfo.InvariantCulture, FlowDirection.LeftToRight,
                typeface, TypeSize, Brushes.White, 1.0);
            elements.Add((formatted, x));
            x += formatted.WidthIncludingTrailingWhitespace + Tracking * TypeSize;
            lineHeight = Math.Max(lineHeight, formatted.Height);
            baseline = Math.Max(baseline, formatted.Baseline);
            count++;
        }
        var width = (int)Math.Ceiling(x + pad + Slant * TypeSize);
        var height = (int)Math.Ceiling(lineHeight + 2 * pad);
        var visual = new DrawingVisual();
        using (var dc = visual.RenderOpen())
        {
            // Shear about the baseline leans the hand into a script.
            dc.PushTransform(new MatrixTransform(1, 0, -Slant, 1, Slant * (pad + baseline), 0));
            foreach (var (formatted, left) in elements) dc.DrawText(formatted, new Point(left, pad + baseline - formatted.Baseline));
            dc.Pop();
        }
        var bitmap = new RenderTargetBitmap(width, height, 96, 96, PixelFormats.Pbgra32);
        bitmap.Render(visual);
        var pixels = new byte[width * height * 4];
        bitmap.CopyPixels(pixels, width * 4, 0);
        var mask = new byte[width * height];
        for (var i = 0; i < mask.Length; i++) mask[i] = pixels[i * 4 + 3];
        return new(mask, width, height, pad, count);
    }

    /// <summary>Thread-free tracing of the raster into pen strokes.</summary>
    public static ScriptArt Trace(Raster raster)
    {
        var strokes = ScriptSkeleton.Strokes(raster.Mask, raster.Width, raster.Height, TypeSize);
        return new ScriptArt
        {
            Width = raster.Width, Height = raster.Height, Pad = raster.Pad, Strokes = strokes,
            LineWidth = TypeSize * .058,
            WriteDuration = Math.Clamp(1.2 + .08 * raster.Characters, 1.6, 2.8),
            inkLength = Math.Max(1, strokes.Sum(ScriptSkeleton.Length)),
            liftCost = TypeSize * .18,
        };
    }

    /// <summary>The written part after <paramref name="travel"/> (0…1) of the performance, pen lifts included, and the nib.</summary>
    public (Geometry Geometry, Point? Tip) Pen(double travel)
    {
        var total = inkLength + liftCost * Math.Max(0, Strokes.Count - 1);
        var budget = Math.Clamp(travel, 0, 1) * total;
        Point? tip = null;
        var geometry = new StreamGeometry();
        using (var ctx = geometry.Open())
        {
            for (var k = 0; k < Strokes.Count && budget > 0; k++)
            {
                if (k > 0 && (budget -= liftCost) <= 0) break;
                var stroke = Strokes[k];
                ctx.BeginFigure(new Point(stroke[0].X, stroke[0].Y), false, false);
                for (var i = 1; i < stroke.Count; i++)
                {
                    PenPoint a = stroke[i - 1], b = stroke[i];
                    var d = Math.Sqrt((b.X - a.X) * (b.X - a.X) + (b.Y - a.Y) * (b.Y - a.Y));
                    if (budget >= d) { ctx.LineTo(new Point(b.X, b.Y), true, true); budget -= d; tip = new Point(b.X, b.Y); }
                    else
                    {
                        var f = budget / d;
                        tip = new Point(a.X + (b.X - a.X) * f, a.Y + (b.Y - a.Y) * f);
                        ctx.LineTo(tip.Value, true, true);
                        budget = 0;
                        break;
                    }
                }
            }
        }
        geometry.Freeze();
        return (geometry, tip);
    }
}
