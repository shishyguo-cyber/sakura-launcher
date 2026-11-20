namespace GardenBoot.Core;

/// <summary>A point on a traced pen stroke, in image pixels (y grows downward).</summary>
public readonly record struct PenPoint(double X, double Y);

/// <summary>
/// Turns rasterized script lettering into single-line pen strokes, so any nickname can be "written" with a
/// constant-width neon line. Same algorithm as macOS (GardenBootCore/ScriptSkeleton.swift): Zhang–Suen
/// thinning, spur pruning, direction-keeping tracing in writing order, junction cleanup and smoothing.
/// </summary>
public static class ScriptSkeleton
{
    // Neighbour order P2…P9 of Zhang–Suen: N, NE, E, SE, S, SW, W, NW.
    private static readonly (int Dx, int Dy)[] Ring = [(0, -1), (1, -1), (1, 0), (1, 1), (0, 1), (-1, 1), (-1, 0), (-1, -1)];

    /// <param name="mask">Row-major coverage, row 0 at the top; values above <paramref name="threshold"/> are ink.</param>
    /// <param name="unit">Nominal type size in pixels; pruning and cleanup thresholds scale with it.</param>
    public static List<List<PenPoint>> Strokes(byte[] mask, int width, int height, double unit, byte threshold = 110)
    {
        if (width <= 2 || height <= 2 || mask.Length != width * height) return [];
        var image = new byte[mask.Length];
        for (var i = 0; i < mask.Length; i++) image[i] = mask[i] > threshold ? (byte)1 : (byte)0;
        // Thinning reads neighbours without bounds checks, so keep a clear 1-pixel border.
        for (var x = 0; x < width; x++) { image[x] = 0; image[(height - 1) * width + x] = 0; }
        for (var y = 0; y < height; y++) { image[y * width] = 0; image[y * width + width - 1] = 0; }
        Thin(image, width);
        Prune(image, width, Math.Max(2, (int)(unit * 0.045)));
        var strokes = RemoveFragments(Trace(image, width, unit), unit);
        return strokes.Select(s => Smooth(Smooth(s, 3), 2)).ToList();
    }

    public static double Length(IReadOnlyList<PenPoint> stroke)
    {
        double total = 0;
        for (var i = 1; i < stroke.Count; i++) total += Distance(stroke[i - 1], stroke[i]);
        return total;
    }

    private static double Distance(PenPoint a, PenPoint b) => Math.Sqrt((b.X - a.X) * (b.X - a.X) + (b.Y - a.Y) * (b.Y - a.Y));

    private static void Thin(byte[] p, int w)
    {
        var ink = Enumerable.Range(0, p.Length).Where(i => p[i] == 1).ToList();
        var n = new byte[8];
        var changed = true;
        while (changed)
        {
            changed = false;
            for (var step = 0; step < 2; step++)
            {
                var remove = new List<int>();
                foreach (var i in ink)
                {
                    if (p[i] == 0) continue;
                    int x = i % w, y = i / w;
                    for (var k = 0; k < 8; k++) n[k] = p[(y + Ring[k].Dy) * w + x + Ring[k].Dx];
                    var b = 0;
                    for (var k = 0; k < 8; k++) b += n[k];
                    if (b < 2 || b > 6) continue;
                    var a = 0;
                    for (var k = 0; k < 8; k++) if (n[k] == 0 && n[(k + 1) % 8] == 1) a++;
                    if (a != 1) continue;
                    if (step == 0 ? (n[0] & n[2] & n[4]) != 0 || (n[2] & n[4] & n[6]) != 0
                                  : (n[0] & n[2] & n[6]) != 0 || (n[0] & n[4] & n[6]) != 0) continue;
                    remove.Add(i);
                }
                if (remove.Count > 0)
                {
                    changed = true;
                    foreach (var i in remove) p[i] = 0;
                }
            }
            ink.RemoveAll(i => p[i] == 0);
        }
    }

    private static List<int> Neighbours(int i, byte[] p, int w)
    {
        int x = i % w, y = i / w;
        var result = new List<int>(4);
        foreach (var (dx, dy) in Ring)
        {
            var j = (y + dy) * w + x + dx;
            if (j >= 0 && j < p.Length && p[j] == 1) result.Add(j);
        }
        return result;
    }

    /// <summary>Removes short branches that end in a junction (thinning artifacts at thick terminals).</summary>
    private static void Prune(byte[] p, int w, int spur)
    {
        for (var pass = 0; pass < 2; pass++)
        {
            for (var i = 0; i < p.Length; i++)
            {
                if (p[i] != 1 || Neighbours(i, p, w).Count != 1) continue;
                var path = new List<int> { i };
                int current = i, previous = -1;
                while (path.Count <= spur)
                {
                    var next = Neighbours(current, p, w).Where(j => j != previous).ToList();
                    if (next.Count != 1) break;
                    previous = current;
                    current = next[0];
                    path.Add(current);
                }
                if (path.Count <= spur && Neighbours(current, p, w).Count >= 3)
                    foreach (var j in path.Take(path.Count - 1)) p[j] = 0;
            }
        }
    }

    private static List<List<PenPoint>> Trace(byte[] p, int w, double unit)
    {
        var visited = new bool[p.Length];
        var remaining = Enumerable.Range(0, p.Length).Where(i => p[i] == 1).ToList();
        PenPoint Point(int i) => new(i % w, i / w);
        var endpointBias = (int)(unit * 0.04);
        var strokes = new List<List<PenPoint>>();
        while (true)
        {
            remaining.RemoveAll(i => visited[i]);
            // Start at the leftmost unvisited pixel, nudging toward free ends so a pen starts at a terminal.
            int best = -1, bestKey = int.MaxValue;
            foreach (var i in remaining)
            {
                var free = Neighbours(i, p, w).Count(j => !visited[j]);
                var key = i % w - (free <= 1 ? endpointBias : 0);
                if (key < bestKey) { bestKey = key; best = i; }
            }
            if (best < 0) break;
            var stroke = new List<PenPoint> { Point(best) };
            visited[best] = true;
            var current = best;
            double dx = 1, dy = 0;
            while (true)
            {
                var options = Neighbours(current, p, w).Where(j => !visited[j]).ToList();
                if (options.Count == 0) break;
                var origin = Point(current);
                double Alignment(int j)
                {
                    double vx = Point(j).X - origin.X, vy = Point(j).Y - origin.Y;
                    return (vx * dx + vy * dy) / Math.Sqrt(vx * vx + vy * vy);
                }
                var next = options.MaxBy(Alignment);
                visited[next] = true;
                var end = Point(next);
                stroke.Add(end);
                var back = stroke[Math.Max(0, stroke.Count - 6)];
                double ux = end.X - back.X, uy = end.Y - back.Y, l = Math.Max(0.001, Math.Sqrt(ux * ux + uy * uy));
                dx = ux / l; dy = uy / l;
                current = next;
            }
            // A dot thins to a pixel or two; give it a short tick so the round cap draws it.
            if (stroke.Count < 3)
            {
                var start = stroke[0];
                stroke = [start, new(start.X + 1, start.Y - 0.5), new(start.X + 2, start.Y - 1)];
            }
            strokes.Add(stroke);
        }
        return strokes;
    }

    /// <summary>Junction leftovers are short pieces lying next to longer strokes; isolated short pieces (dots) stay.</summary>
    private static List<List<PenPoint>> RemoveFragments(List<List<PenPoint>> strokes, double unit)
    {
        double minimum = unit * 0.07, reach = unit * 0.08;
        var longStrokes = strokes.Where(s => Length(s) >= minimum).ToList();
        return strokes.Where(stroke =>
        {
            if (Length(stroke) >= minimum) return true;
            var c = stroke[stroke.Count / 2];
            return !longStrokes.Any(other => other.Any(q => Distance(q, c) < reach));
        }).ToList();
    }

    private static List<PenPoint> Smooth(List<PenPoint> s, int radius)
    {
        if (s.Count <= 2 * radius + 1) return s;
        var result = new List<PenPoint>(s.Count);
        for (var i = 0; i < s.Count; i++)
        {
            int lo = Math.Max(0, i - radius), hi = Math.Min(s.Count - 1, i + radius);
            double x = 0, y = 0;
            for (var j = lo; j <= hi; j++) { x += s[j].X; y += s[j].Y; }
            result.Add(new(x / (hi - lo + 1), y / (hi - lo + 1)));
        }
        return result;
    }
}
