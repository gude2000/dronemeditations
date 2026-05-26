import Foundation

/// Discovers audio files shipped in the app bundle's `Samples` subfolder
/// at launch so the in-app sample picker can offer them with a single tap
/// (no Files-app round-trip). Build setup: add the `Samples/` folder to
/// the Xcode project as a folder reference (blue icon) so any file
/// dropped in it ships in the bundle without further edits.
enum BundledSampleStore {

    struct Entry: Identifiable, Hashable {
        let id: String           // bundle path (unique)
        let name: String         // display name (without extension)
        let url: URL
        let category: String     // first path component or "Samples"
    }

    /// Scans Bundle.main for known audio extensions inside the `Samples`
    /// folder, recursively walking subdirectories (Field/, Atmospheric/,
    /// Cosmic/, Instruments/, Urban/, etc.) so any nested layout shows up
    /// grouped by subfolder. Memoized after first call.
    ///
    /// Implementation note: `Bundle.urls(forResourcesWithExtension:subdirectory:)`
    /// does NOT recurse into subdirectories — it only matches files at
    /// the exact level specified. That silently dropped 41 categorized
    /// samples after we organized them into subfolders. We now use
    /// FileManager.enumerator which walks the directory tree.
    static let all: [Entry] = {
        var found: [Entry] = []
        let exts: Set<String> = ["wav", "mp3", "m4a", "aac", "aif", "aiff", "caf"]

        let samplesURL = Bundle.main.bundleURL.appendingPathComponent("Samples")
        if let enumerator = FileManager.default.enumerator(
            at: samplesURL,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) {
            for case let url as URL in enumerator {
                if exts.contains(url.pathExtension.lowercased()) {
                    found.append(entry(for: url))
                }
            }
        }
        // Sort alphabetically by name for stable display order within each
        // category section (the UI groups by `entry.category` separately).
        return found.sorted { $0.name.lowercased() < $1.name.lowercased() }
    }()

    private static func entry(for url: URL) -> Entry {
        let stem = url.deletingPathExtension().lastPathComponent
        // If the user nests files in subfolders under Samples/<group>/...,
        // surface the group name as the category. Otherwise everything
        // sits under a single "Samples" header.
        let pathComps = url.pathComponents
        var category = "Samples"
        if let idx = pathComps.firstIndex(of: "Samples"),
           idx + 1 < pathComps.count - 1 {
            category = pathComps[idx + 1]
        }
        return Entry(id: url.path,
                     name: stem,
                     url: url,
                     category: category)
    }
}
