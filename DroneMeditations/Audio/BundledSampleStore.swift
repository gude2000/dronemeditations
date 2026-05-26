import Foundation

/// Discovers audio files for the in-app sample picker from TWO sources:
///
///   1. The app bundle's `Samples/` folder, scanned once and memoized
///      (the layout never changes at runtime).
///   2. The user's `Documents/User samples/` folder, re-scanned on every
///      access so files the user drops in via the Files app appear in
///      the picker immediately (no app restart needed). Made possible by
///      `UIFileSharingEnabled = YES` + `LSSupportsOpeningDocumentsInPlace
///      = YES` in Info.plist, which exposes the app's container to the
///      Files app.
///
/// Build setup: the bundle Samples/ folder must be added to the Xcode
/// project as a folder reference (blue icon), so any file dropped in
/// pre-build ships in the bundle without further edits. See
/// `Samples/README.md` for details.
enum BundledSampleStore {

    struct Entry: Identifiable, Hashable {
        let id: String           // bundle path or Documents path (unique)
        let name: String         // display name (without extension)
        let url: URL
        let category: String     // first path component or "Samples"
    }

    /// Combined catalogue used by the picker. Bundle entries are cached;
    /// Documents entries are re-scanned each time so newly dropped user
    /// files appear immediately. Sorted alphabetically per category by
    /// the consumer (`Dictionary(grouping:by:)` in the strip view).
    static var all: [Entry] {
        return bundleEntries + userDocumentsEntries()
    }

    // MARK: - Bundle scan (memoized)
    //
    // `Bundle.urls(forResourcesWithExtension:subdirectory:)` does NOT
    // recurse into subdirectories — it only matches files at the exact
    // level specified. That silently dropped 41 categorized samples after
    // we organized them into subfolders. FileManager.enumerator walks the
    // directory tree.
    private static let bundleEntries: [Entry] = {
        let samplesURL = Bundle.main.bundleURL.appendingPathComponent("Samples")
        return scanFolder(samplesURL, rootName: "Samples")
            .sorted { $0.name.lowercased() < $1.name.lowercased() }
    }()

    // MARK: - Documents/User samples scan (fresh each call)

    /// Documents/User samples — the runtime drop-in folder. Created on
    /// first launch by `ensureUserSamplesFolderExists()`. Anything
    /// dropped here (via Files app, AirDrop, share sheet → "Save to
    /// Drone Meditations", etc.) appears in the picker under
    /// "User samples". Re-scanned on every access so newly added files
    /// show without an app restart.
    private static func userDocumentsEntries() -> [Entry] {
        guard let userSamplesURL = userSamplesFolderURL else { return [] }
        return scanFolder(userSamplesURL, rootName: "User samples")
            .sorted { $0.name.lowercased() < $1.name.lowercased() }
    }

    /// Absolute URL of `<app-Documents>/User samples`, or nil if the
    /// Documents directory can't be located (effectively never on iOS).
    static var userSamplesFolderURL: URL? {
        guard let docs = FileManager.default.urls(
            for: .documentDirectory, in: .userDomainMask
        ).first else { return nil }
        return docs.appendingPathComponent("User samples", isDirectory: true)
    }

    /// Called once on app launch from `DroneMeditationsApp.init`. Creates
    /// `Documents/User samples/` if it doesn't exist + drops a README so
    /// users browsing the app's container in Files see what the folder
    /// is for. Idempotent.
    static func ensureUserSamplesFolderExists() {
        guard let folder = userSamplesFolderURL else { return }
        let fm = FileManager.default
        if !fm.fileExists(atPath: folder.path) {
            try? fm.createDirectory(at: folder, withIntermediateDirectories: true)
        }
        let readme = folder.appendingPathComponent("README.txt")
        if !fm.fileExists(atPath: readme.path) {
            let body = """
            Drone Meditations — Your Samples
            ==================================

            Drop audio files into this folder (via the Files app, AirDrop,
            or share-sheet → "Save to Drone Meditations") and they'll
            appear under "User samples" in any oscillator's Bundled ▾
            picker — no app restart needed.

            Supported formats: WAV, MP3, M4A, AAC, AIF / AIFF, CAF.

            Tips:
            • 4–10 second loops feel natural at most pitches.
            • Stereo files preserve their stereo image; mono works fine.
            • Files stay here until you delete them. They don't sync
              between devices unless you put them in iCloud Drive
              yourself.

            Looking for the samples that shipped with the app? Those are
            in the same Bundled ▾ picker under Atmospheric / Cosmic /
            Field / Instruments / etc. — they're inside the app and you
            can't see them from here.
            """
            try? body.write(to: readme, atomically: true, encoding: .utf8)
        }
    }

    // MARK: - Shared scanner

    private static let audioExts: Set<String> = [
        "wav", "mp3", "m4a", "aac", "aif", "aiff", "caf"
    ]

    /// Walks `rootURL` recursively and yields an `Entry` per audio file.
    /// `rootName` is the path component that identifies the root (either
    /// "Samples" for the bundle scan or "User samples" for the Documents
    /// scan) — anything one level deeper than that becomes the entry's
    /// `category`. Files sitting directly inside the root get categorised
    /// as `rootName` itself.
    private static func scanFolder(_ rootURL: URL, rootName: String) -> [Entry] {
        var found: [Entry] = []
        guard let enumerator = FileManager.default.enumerator(
            at: rootURL,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return found }

        for case let url as URL in enumerator {
            guard audioExts.contains(url.pathExtension.lowercased()) else { continue }
            let stem = url.deletingPathExtension().lastPathComponent
            let category = categoryFor(url: url, rootName: rootName)
            found.append(Entry(id: url.path, name: stem, url: url, category: category))
        }
        return found
    }

    private static func categoryFor(url: URL, rootName: String) -> String {
        let pathComps = url.pathComponents
        // Find the index of the root component and use the next one as
        // category. If the file sits directly inside the root, fall back
        // to the root name itself.
        if let idx = pathComps.firstIndex(of: rootName),
           idx + 1 < pathComps.count - 1 {
            return pathComps[idx + 1]
        }
        return rootName
    }
}
