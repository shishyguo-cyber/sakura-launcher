import Foundation

/// "检查更新" rules (launcher-spec/UPDATES.md §3): semantic-version precedence and choosing a newer release.
public enum UpdateRules {
    public static let checkInterval: Double = 7 * 24 * 3600
    public static let releasesURL = URL(string: "https://api.github.com/repos/shishyguo-cyber/sakura-launcher/releases?per_page=20")!

    public struct Version: Equatable, Sendable {
        public let core: [Int]
        public let prerelease: [String]
        public var text: String { core.map(String.init).joined(separator: ".") + (prerelease.isEmpty ? "" : "-" + prerelease.joined(separator: ".")) }
    }

    public struct Release: Equatable, Sendable {
        public let tag: String
        public let url: String
        public let draft: Bool
        public let prerelease: Bool
        public init(tag: String, url: String, draft: Bool, prerelease: Bool) {
            self.tag = tag; self.url = url; self.draft = draft; self.prerelease = prerelease
        }
    }

    public struct Available: Equatable, Sendable {
        public let version: String
        public let url: String
    }

    public static func parse(_ raw: String) -> Version? {
        var text = Substring(raw.trimmingCharacters(in: .whitespaces))
        if text.first == "v" || text.first == "V" { text = text.dropFirst() }
        if let plus = text.firstIndex(of: "+") { text = text[..<plus] } // build metadata does not affect precedence
        let parts = text.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
        let numbers = parts[0].split(separator: ".", omittingEmptySubsequences: false)
        guard numbers.count == 3 else { return nil }
        var core: [Int] = []
        for n in numbers {
            guard !n.isEmpty, n.allSatisfy(\.isASCII), n.allSatisfy(\.isNumber), n == "0" || n.first != "0", let value = Int(n) else { return nil }
            core.append(value)
        }
        var prerelease: [String] = []
        if parts.count == 2 {
            prerelease = parts[1].split(separator: ".", omittingEmptySubsequences: false).map(String.init)
            guard !prerelease.isEmpty, prerelease.allSatisfy({ !$0.isEmpty && $0.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") } }) else { return nil }
        }
        return Version(core: core, prerelease: prerelease)
    }

    /// -1, 0 or 1; nil when either side is not a valid version.
    public static func compare(_ a: String, _ b: String) -> Int? {
        guard let x = parse(a), let y = parse(b) else { return nil }
        return compare(x, y)
    }

    static func compare(_ x: Version, _ y: Version) -> Int {
        for (p, q) in zip(x.core, y.core) where p != q { return p < q ? -1 : 1 }
        switch (x.prerelease.isEmpty, y.prerelease.isEmpty) {
        case (true, true): return 0
        case (true, false): return 1
        case (false, true): return -1
        case (false, false): break
        }
        for (p, q) in zip(x.prerelease, y.prerelease) where p != q {
            switch (Int(p), Int(q)) {
            case let (m?, n?): return m < n ? -1 : 1
            case (.some, nil): return -1
            case (nil, .some): return 1
            case (nil, nil): return p < q ? -1 : 1
            }
        }
        return x.prerelease.count == y.prerelease.count ? 0 : (x.prerelease.count < y.prerelease.count ? -1 : 1)
    }

    public static func newest(_ releases: [Release], current: String) -> Available? {
        guard let now = parse(current) else { return nil }
        let allowPrerelease = !now.prerelease.isEmpty
        var best: (Version, Release)?
        for release in releases where !release.draft {
            guard let version = parse(release.tag), allowPrerelease || (version.prerelease.isEmpty && !release.prerelease),
                  compare(version, now) > 0 else { continue }
            if best == nil || compare(version, best!.0) > 0 { best = (version, release) }
        }
        return best.map { Available(version: $0.0.text, url: $0.1.url) }
    }

    public static func isDue(lastCheckAt: Double?, now: Double) -> Bool {
        guard let lastCheckAt else { return true }
        return now < lastCheckAt || now - lastCheckAt >= checkInterval
    }

    /// GitHub's release list (`tag_name`, `html_url`, `draft`, `prerelease`); malformed entries are skipped.
    public static func decodeReleases(_ data: Data) throws -> [Release] {
        guard let list = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            throw CocoaError(.propertyListReadCorrupt)
        }
        return list.compactMap { item in
            guard let tag = item["tag_name"] as? String, let url = item["html_url"] as? String,
                  url.hasPrefix("https://") else { return nil }
            return Release(tag: tag, url: url, draft: item["draft"] as? Bool ?? false, prerelease: item["prerelease"] as? Bool ?? false)
        }
    }
}
