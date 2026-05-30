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

// MARK: - .dronepreset file sharing (v1.1)
//
// Pack a UserPreset (plus any audio sample it references) into a
// self-contained `.dronepreset` JSON file the user can AirDrop / save
// to Files / email between devices. Unpacking writes embedded samples
// back into DroneSamples/ so the preset's sampleStoredFilename
// references resolve on the receiving device.

enum UserPresetSharing {
    /// Schema version — bump only on backward-incompatible changes.
    private static let currentVersion = 1

    /// File extension we own. Wired up to a custom UTI in Info.plist
    /// so tapping a `.dronepreset` in Files / Mail / AirDrop hands it
    /// to us.
    static let fileExtension = "dronepreset"

    /// On-disk file shape — Codable mirror of the JSON.
    /// {
    ///   "version": 1,
    ///   "preset":  { …UserPreset… },
    ///   "samples": [ { "filename": "<uuid>.wav",
    ///                  "data":     "<base64-encoded audio>" }, … ]
    /// }
    private struct Envelope: Codable {
        let version: Int
        let preset: UserPreset
        let samples: [Sample]

        struct Sample: Codable {
            let filename: String
            let data: Data        // base64 in JSON, raw bytes after decode
        }
    }

    enum ImportError: LocalizedError {
        case readFailed
        case decodeFailed
        case unsupportedVersion(Int)

        var errorDescription: String? {
            switch self {
            case .readFailed:            return "Couldn't read the preset file."
            case .decodeFailed:          return "Preset file is malformed or not a Drone Meditations preset."
            case .unsupportedVersion(let v):
                return "This preset uses a newer format (v\(v)) than this version of Drone Meditations understands. Please update."
            }
        }
    }

    /// Pack the preset (plus any referenced sample audio) into a
    /// `.dronepreset` file in the temp directory. Returns the URL
    /// ready to hand to ShareLink. Caller doesn't need to clean up —
    /// the system manages tmp on its own schedule.
    static func export(_ preset: UserPreset) throws -> URL {
        var samples: [Envelope.Sample] = []
        var seen = Set<String>()
        for voice in preset.oscillators {
            guard let stored = voice.sampleStoredFilename, !seen.contains(stored) else { continue }
            seen.insert(stored)
            if let url = UserPresetStore.url(forStoredSample: stored),
               let data = try? Data(contentsOf: url) {
                samples.append(.init(filename: stored, data: data))
            }
        }

        let env = Envelope(version: currentVersion, preset: preset, samples: samples)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(env)

        let safeName = sanitizeFilename(preset.name)
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(safeName)
            .appendingPathExtension(fileExtension)
        if FileManager.default.fileExists(atPath: url.path) {
            try? FileManager.default.removeItem(at: url)
        }
        try data.write(to: url, options: .atomic)
        return url
    }

    /// Decode a `.dronepreset` file and return the preset (with a
    /// freshly-issued id so it never collides with one already on this
    /// device). Embedded samples are materialized into DroneSamples/
    /// so the preset's `sampleStoredFilename` references resolve.
    static func importPreset(from url: URL) throws -> UserPreset {
        // Files-app URLs are sandbox-protected — bracket the read.
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }

        guard let raw = try? Data(contentsOf: url) else { throw ImportError.readFailed }
        let env: Envelope
        do {
            env = try JSONDecoder().decode(Envelope.self, from: raw)
        } catch {
            throw ImportError.decodeFailed
        }
        guard env.version <= currentVersion else {
            throw ImportError.unsupportedVersion(env.version)
        }

        // Materialize embedded samples. Leave any pre-existing local
        // file with the same name alone — another preset on this
        // device might reference it.
        let samplesDir = UserPresetStore.samplesDirectory
        for s in env.samples {
            let dest = samplesDir.appendingPathComponent(s.filename)
            if !FileManager.default.fileExists(atPath: dest.path) {
                try? s.data.write(to: dest, options: .atomic)
            }
        }

        // Re-id the preset so importing twice creates two entries
        // rather than overwriting. Keep original createdAt so the
        // receiver sees when the author saved it.
        let p = env.preset
        return UserPreset(
            id: UserPreset.newId(),
            name: p.name,
            createdAt: p.createdAt,
            keyId: p.keyId,
            octave: p.octave,
            chordId: p.chordId,
            tuningId: p.tuningId,
            masterVolume: p.masterVolume,
            oscillators: p.oscillators
        )
    }

    /// Strip filesystem-hostile characters from the preset name so the
    /// exported filename works on iOS / macOS / iCloud Drive without
    /// surprise mangling. Trims to 80 chars.
    private static func sanitizeFilename(_ name: String) -> String {
        var s = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.isEmpty { s = "Drone Preset" }
        let bad: Set<Character> = ["/", ":", "\\", "?", "*", "\"", "<", ">", "|"]
        s = String(s.map { bad.contains($0) ? "-" : $0 })
        if s.count > 80 { s = String(s.prefix(80)) }
        return s
    }
}
