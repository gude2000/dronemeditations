import Foundation

/// Persistent storage for user presets.
/// - Preset metadata: JSON in UserDefaults under `userPresets`.
/// - Sample audio files: copied into `Documents/DroneSamples/` so they
///   survive between launches (and can be re-loaded by name when a preset
///   that references them is restored).
enum UserPresetStore {
    private static let key = "userPresets"

    static func load() -> [UserPreset] {
        guard let data = UserDefaults.standard.data(forKey: key) else { return [] }
        return (try? JSONDecoder().decode([UserPreset].self, from: data)) ?? []
    }

    static func save(_ presets: [UserPreset]) {
        if let data = try? JSONEncoder().encode(presets) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }

    /// Directory holding persisted sample audio files. Created on first access.
    static var samplesDirectory: URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let dir = docs.appendingPathComponent("DroneSamples", isDirectory: true)
        if !FileManager.default.fileExists(atPath: dir.path) {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        return dir
    }

    /// Copy a sample file into the app's storage so it can be referenced by
    /// future preset loads. Returns the stored filename (relative to
    /// `samplesDirectory`).
    static func persistSample(from sourceURL: URL) throws -> String {
        let didStart = sourceURL.startAccessingSecurityScopedResource()
        defer { if didStart { sourceURL.stopAccessingSecurityScopedResource() } }
        let ext = sourceURL.pathExtension
        let storedName = "\(UUID().uuidString)" + (ext.isEmpty ? "" : ".\(ext)")
        let destURL = samplesDirectory.appendingPathComponent(storedName)
        try FileManager.default.copyItem(at: sourceURL, to: destURL)
        return storedName
    }

    /// Resolve a stored filename back to a URL the engine can load.
    static func url(forStoredSample filename: String) -> URL? {
        let url = samplesDirectory.appendingPathComponent(filename)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    /// Delete a sample file if no other preset still references it.
    static func deleteSampleIfUnused(_ filename: String, presets: [UserPreset]) {
        let stillUsed = presets.contains { p in
            p.oscillators.contains { $0.sampleStoredFilename == filename }
        }
        if !stillUsed {
            let url = samplesDirectory.appendingPathComponent(filename)
            try? FileManager.default.removeItem(at: url)
        }
    }
}
