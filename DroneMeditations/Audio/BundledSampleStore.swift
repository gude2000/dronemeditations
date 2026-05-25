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
    /// subdirectory (and root, as a fallback). Memoized after first call.
    static let all: [Entry] = {
        var found: [Entry] = []
        let exts = ["wav", "mp3", "m4a", "aac", "aif", "aiff", "caf"]
        for ext in exts {
            if let urls = Bundle.main.urls(forResourcesWithExtension: ext,
                                           subdirectory: "Samples") {
                for u in urls { found.append(entry(for: u)) }
            }
        }
        // Sort alphabetically by name for stable display order.
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
