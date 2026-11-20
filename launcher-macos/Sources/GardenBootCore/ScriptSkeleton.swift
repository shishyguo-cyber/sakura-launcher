import CoreGraphics
import Foundation

/// Turns rasterized script lettering into single-line pen strokes, so any name can be "written"
/// with a constant-width neon line instead of revealing filled glyph outlines.
///
/// Steps: Zhang–Suen thinning to a one-pixel skeleton, pruning of short spurs that thinning leaves at
/// thick terminals, greedy tracing that prefers to keep the current direction through junctions, removal
/// of junction leftovers, and light smoothing. Strokes come out roughly in writing order (left to right).
public enum ScriptSkeleton {
    /// - Parameters:
    ///   - mask: row-major coverage, row 0 is the top row; values above `threshold` count as ink.
    ///   - unit: the nominal type size in pixels; pruning and cleanup thresholds scale with it.
    /// - Returns: strokes in image coordinates (y grows downward).
    public static func strokes(mask: [UInt8], width: Int, height: Int, unit: Double,
                               threshold: UInt8 = 110) -> [[CGPoint]] {
        guard width > 2, height > 2, mask.count == width * height else { return [] }
        var image = mask.map { $0 > threshold ? UInt8(1) : 0 }
        // Thinning reads neighbours without bounds checks, so keep a clear 1-pixel border.
        for x in 0..<width { image[x] = 0; image[(height - 1) * width + x] = 0 }
        for y in 0..<height { image[y * width] = 0; image[y * width + width - 1] = 0 }
        thin(&image, width: width, height: height)
        prune(&image, width: width, height: height, spur: max(2, Int(unit * 0.045)))
        var strokes = trace(image, width: width, height: height, unit: unit)
        strokes = removeFragments(strokes, unit: unit)
        return strokes.map { smooth(smooth($0, radius: 3), radius: 2) }
    }

    public static func length(_ stroke: [CGPoint]) -> Double {
        zip(stroke, stroke.dropFirst()).reduce(0) { $0 + hypot($1.1.x - $1.0.x, $1.1.y - $1.0.y) }
    }

    // Neighbour order P2…P9 of Zhang–Suen: N, NE, E, SE, S, SW, W, NW.
    private static let ring = [(0, -1), (1, -1), (1, 0), (1, 1), (0, 1), (-1, 1), (-1, 0), (-1, -1)]

    private static func thin(_ p: inout [UInt8], width w: Int, height h: Int) {
        var ink = (0..<p.count).filter { p[$0] == 1 }
        var changed = true
        var n = [UInt8](repeating: 0, count: 8)
        while changed {
            changed = false
            for step in 0..<2 {
                var remove: [Int] = []
                for i in ink where p[i] == 1 {
                    let x = i % w, y = i / w
                    for k in 0..<8 { n[k] = p[(y + ring[k].1) * w + x + ring[k].0] }
                    let b = n.reduce(0) { $0 + Int($1) }
                    guard b >= 2, b <= 6 else { continue }
                    var a = 0
                    for k in 0..<8 where n[k] == 0 && n[(k + 1) % 8] == 1 { a += 1 }
                    guard a == 1 else { continue }
                    if step == 0 {
                        guard n[0] & n[2] & n[4] == 0, n[2] & n[4] & n[6] == 0 else { continue }
                    } else {
                        guard n[0] & n[2] & n[6] == 0, n[0] & n[4] & n[6] == 0 else { continue }
                    }
                    remove.append(i)
                }
                if !remove.isEmpty {
                    changed = true
                    for i in remove { p[i] = 0 }
                }
            }
            ink.removeAll { p[$0] == 0 }
        }
    }

    private static func neighbours(_ i: Int, _ p: [UInt8], _ w: Int) -> [Int] {
        let x = i % w, y = i / w
        var result: [Int] = []
        result.reserveCapacity(4)
        for (dx, dy) in ring {
            let j = (y + dy) * w + x + dx
            if j >= 0, j < p.count, p[j] == 1 { result.append(j) }
        }
        return result
    }

    /// Removes short branches that end in a junction (thinning artifacts at thick terminals).
    private static func prune(_ p: inout [UInt8], width w: Int, height h: Int, spur: Int) {
        for _ in 0..<2 {
            for i in 0..<p.count where p[i] == 1 && neighbours(i, p, w).count == 1 {
                var path = [i], current = i, previous = -1
                while path.count <= spur {
                    let next = neighbours(current, p, w).filter { $0 != previous }
                    if next.count != 1 { break }
                    previous = current
                    current = next[0]
                    path.append(current)
                }
                if path.count <= spur, neighbours(current, p, w).count >= 3 {
                    for j in path.dropLast() { p[j] = 0 }
                }
            }
        }
    }

    private static func trace(_ p: [UInt8], width w: Int, height h: Int, unit: Double) -> [[CGPoint]] {
        var visited = [Bool](repeating: false, count: p.count)
        var remaining = (0..<p.count).filter { p[$0] == 1 }
        func point(_ i: Int) -> CGPoint { CGPoint(x: i % w, y: i / w) }
        let endpointBias = Int(unit * 0.04)
        var strokes: [[CGPoint]] = []
        while true {
            remaining.removeAll { visited[$0] }
            // Start at the leftmost unvisited pixel, nudging toward free ends so a pen starts at a terminal.
            var best = -1, bestKey = Int.max
            for i in remaining {
                let free = neighbours(i, p, w).filter { !visited[$0] }.count
                let key = i % w - (free <= 1 ? endpointBias : 0)
                if key < bestKey { bestKey = key; best = i }
            }
            guard best >= 0 else { break }
            var stroke = [point(best)]
            visited[best] = true
            var current = best
            var direction = CGVector(dx: 1, dy: 0)
            while true {
                let options = neighbours(current, p, w).filter { !visited[$0] }
                guard !options.isEmpty else { break }
                let origin = point(current)
                func alignment(_ j: Int) -> CGFloat {
                    let v = CGVector(dx: point(j).x - origin.x, dy: point(j).y - origin.y)
                    return (v.dx * direction.dx + v.dy * direction.dy) / hypot(v.dx, v.dy)
                }
                let next = options.max { alignment($0) < alignment($1) }!
                visited[next] = true
                let end = point(next)
                stroke.append(end)
                let back = stroke[max(0, stroke.count - 6)]
                let v = CGVector(dx: end.x - back.x, dy: end.y - back.y)
                let l = max(0.001, hypot(v.dx, v.dy))
                direction = CGVector(dx: v.dx / l, dy: v.dy / l)
                current = next
            }
            // A dot thins to a pixel or two; give it a short tick so the round cap draws it.
            if stroke.count < 3 {
                let p = stroke[0]
                stroke = [p, CGPoint(x: p.x + 1, y: p.y - 0.5), CGPoint(x: p.x + 2, y: p.y - 1)]
            }
            strokes.append(stroke)
        }
        return strokes
    }

    /// Junction leftovers are short pieces lying next to longer strokes; isolated short pieces (dots) stay.
    private static func removeFragments(_ strokes: [[CGPoint]], unit: Double) -> [[CGPoint]] {
        let minimum = unit * 0.07, reach = unit * 0.08
        let long = strokes.filter { length($0) >= minimum }
        return strokes.filter { stroke in
            if length(stroke) >= minimum { return true }
            let c = stroke[stroke.count / 2]
            return !long.contains { other in other.contains { hypot($0.x - c.x, $0.y - c.y) < reach } }
        }
    }

    private static func smooth(_ s: [CGPoint], radius: Int) -> [CGPoint] {
        guard s.count > 2 * radius + 1 else { return s }
        return s.indices.map { i in
            let lo = max(0, i - radius), hi = min(s.count - 1, i + radius)
            var x = 0.0, y = 0.0
            for j in lo...hi { x += s[j].x; y += s[j].y }
            let n = Double(hi - lo + 1)
            return CGPoint(x: x / n, y: y / n)
        }
    }
}
