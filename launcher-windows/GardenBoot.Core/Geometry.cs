namespace GardenBoot.Core;

/// <summary>Axis-aligned rectangle in device-independent units (Y grows downward on Windows; the maths does not care).</summary>
public readonly record struct Box(double X, double Y, double Width, double Height)
{
    public static readonly Box Empty = new(0, 0, 0, 0);
    public double Right => X + Width;
    public double Bottom => Y + Height;
    public double CenterX => X + Width / 2;
    public double CenterY => Y + Height / 2;
    public bool Contains(Box other) => other.X >= X && other.Y >= Y && other.Right <= Right && other.Bottom <= Bottom;
}

/// <summary>Where the overlay sits before it knows the target window, and how it travels onto that window.</summary>
public static class OverlayGeometry
{
    public const double LaunchCoverage = 0.72;
    public const double LaunchMaxWidth = 1120;
    public const double FollowTolerance = 2;

    /// <summary>
    /// The largest rectangle with <paramref name="aspect"/> inside the central 72% of <paramref name="visible"/>, no wider
    /// than 1120, size floored to whole units and origin rounded half away from zero (matches the macOS version).
    /// </summary>
    public static Box LaunchFrame(Box visible, double aspect = 16.0 / 9.0, double coverage = LaunchCoverage)
    {
        if (visible.Width <= 0 || visible.Height <= 0 || !double.IsFinite(aspect) || aspect <= 0) return Box.Empty;
        var ratio = double.IsFinite(coverage) && coverage >= .4 && coverage <= .9 ? coverage : LaunchCoverage;
        double boxW = visible.Width * ratio, boxH = visible.Height * ratio;
        double w = boxW, h = boxW / aspect;
        if (h > boxH) (w, h) = (boxH * aspect, boxH);
        if (w > LaunchMaxWidth) (w, h) = (LaunchMaxWidth, LaunchMaxWidth / aspect);
        w = Math.Floor(w);
        h = Math.Floor(h);
        return new Box(Math.Round(visible.CenterX - w / 2, MidpointRounding.AwayFromZero),
                       Math.Round(visible.CenterY - h / 2, MidpointRounding.AwayFromZero), w, h);
    }

    /// <summary>Cubic smoothstep clamped to 0..1, used for glides and fades.</summary>
    public static double Ease(double t)
    {
        var x = Math.Clamp(t, 0, 1);
        return x * x * (3 - 2 * x);
    }

    public static Box Interpolate(Box from, Box to, double progress)
    {
        var k = Ease(progress);
        double Mix(double a, double b) => a + (b - a) * k;
        return new Box(Mix(from.X, to.X), Mix(from.Y, to.Y), Mix(from.Width, to.Width), Mix(from.Height, to.Height));
    }

    /// <summary>True when the target window moved or resized enough that the overlay should re-dock onto it.</summary>
    public static bool ShouldFollow(Box current, Box latest) =>
        Math.Abs(current.X - latest.X) > FollowTolerance || Math.Abs(current.Y - latest.Y) > FollowTolerance
        || Math.Abs(current.Right - latest.Right) > FollowTolerance || Math.Abs(current.Bottom - latest.Bottom) > FollowTolerance;
}
