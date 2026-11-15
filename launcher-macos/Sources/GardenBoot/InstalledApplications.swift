import Foundation

struct InstalledApplication: Identifiable, Sendable {
    let bundleID: String
    let name: String
    let url: URL
    var id: String { bundleID }
}

enum InstalledApplications {
    static var roots: [URL] {
        [URL(fileURLWithPath: "/Applications"), FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications"),
         URL(fileURLWithPath: "/System/Applications")]
    }
    /// Only root applications and applications in one immediate subfolder; never descend into app bundles.
    static func read(roots: [URL] = roots, excluding ownID: String? = Bundle.main.bundleIdentifier) -> [InstalledApplication] {
        let fm = FileManager.default
        func children(_ folder: URL) -> [URL] {
            (try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])) ?? []
        }
        var found: [String: InstalledApplication] = [:]
        for root in roots {
            for child in children(root) {
                let candidates = child.pathExtension.lowercased() == "app" ? [child] :
                    ((try? child.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true ? children(child) : [])
                for url in candidates where url.pathExtension.lowercased() == "app" {
                    guard let bundle = Bundle(url: url), let id = bundle.bundleIdentifier, !id.isEmpty,
                          id != ownID, id != "local.gardenboot.GardenBoot", found[id] == nil else { continue }
                    let localized = bundle.localizedInfoDictionary
                    let displayName = fm.displayName(atPath: url.path)
                    let fallback = displayName.lowercased().hasSuffix(".app") ? String(displayName.dropLast(4)) : displayName
                    let name = localized?["CFBundleDisplayName"] as? String ?? localized?["CFBundleName"] as? String ?? fallback
                    found[id] = InstalledApplication(bundleID: id, name: name, url: url)
                }
            }
        }
        return found.values.sorted {
            let order = $0.name.localizedCaseInsensitiveCompare($1.name)
            return order == .orderedSame ? $0.bundleID < $1.bundleID : order == .orderedAscending
        }
    }
}
