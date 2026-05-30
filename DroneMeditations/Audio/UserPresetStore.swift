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

// MARK: - iCloud preset sync (v1.1)
//
// Mirrors the user-preset metadata list to NSUbiquitousKeyValueStore
// (KVS) so iPhone and iPad signed into the same Apple ID stay in sync
// without any user action. Sample audio stays device-local — KVS has
// a 1 MB total budget which a single high-quality WAV would blow
// instantly. For samples, the user falls back to manual .dronepreset
// sharing (AirDrop / Files / Mail) which is now first-class.
//
// SYNC SHAPE
//   KVS key "userPresets" → JSON [UserPreset]
//   Up to 50 most-recent presets, additive union of (local ∪ cloud).
//
// SEMANTICS
//   • On local save / delete: push(local ∪ cloud, dedup by id, top 50).
//   • On didChangeExternallyNotification: pull cloud and add any
//     presets we don't already have locally. Deletions DO NOT
//     propagate across devices — if the user wants a preset gone
//     everywhere, they delete on each device. This protects against
//     accidental cross-device wipes.
//   • Conflict by id (same id, different content): cloud wins on the
//     local merge path; local wins on the next push. In practice ids
//     are random per save, so collisions are vanishingly unlikely
//     unless the same .dronepreset file was imported twice — which
//     is fine, the importer always re-ids.
//
// ENTITLEMENT
//   Reads / writes silently no-op without the
//   `com.apple.developer.ubiquity-kvstore-identifier` entitlement.
//   The app builds and runs fine — sync just doesn't activate. Add
//   the entitlement (see DroneMeditations.entitlements + enable
//   iCloud capability on the App ID in Apple Developer portal) to
//   light it up.

import Combine

@MainActor
final class UserPresetCloudSync {
    static let shared = UserPresetCloudSync()
    private init() {}

    private static let kvsKey = "userPresets"
    /// Cap on entries we mirror. KVS limit is 1 MB total per app and
    /// presets aren't tiny (LFO arrays, drift config, all FX state).
    /// 50 keeps us well inside the budget and still covers active
    /// users — heavy users routinely sit at 20-30 saved presets.
    private static let maxPresets = 50

    private var onIncoming: (([UserPreset]) -> Void)?
    private var observer: NSObjectProtocol?

    /// Begin sync. Call once at app start with a closure that knows
    /// how to merge incoming cloud presets into the local list.
    func start(onIncoming: @escaping ([UserPreset]) -> Void) {
        guard observer == nil else { return }   // idempotent
        self.onIncoming = onIncoming

        let store = NSUbiquitousKeyValueStore.default
        observer = NotificationCenter.default.addObserver(
            forName: NSUbiquitousKeyValueStore.didChangeExternallyNotification,
            object: store,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in self.onIncoming?(self.loadFromCloud()) }
        }
        // Kick a synchronize + initial pull so newly-installed devices
        // catch up with whatever's already in the cloud.
        store.synchronize()
        onIncoming(loadFromCloud())
    }

    /// Push the current local preset list to iCloud. Caller passes the
    /// FULL local list; we compute the union with whatever's already
    /// in the cloud (so deletes from device A don't wipe out presets
    /// device B added) and trim to maxPresets.
    func push(_ local: [UserPreset]) {
        let cloud = loadFromCloud()
        let cloudById = Dictionary(uniqueKeysWithValues: cloud.map { ($0.id, $0) })
        // Local wins on collision (user just edited / saved that id).
        var merged = local
        let localIds = Set(local.map(\.id))
        for cp in cloud where !localIds.contains(cp.id) {
            merged.append(cp)
        }
        _ = cloudById   // silence unused — kept in case we add LWW later
        // Sort newest-first so the top-N we keep are the most recent.
        merged.sort { $0.createdAt > $1.createdAt }
        let trimmed = Array(merged.prefix(Self.maxPresets))
        guard let data = try? JSONEncoder().encode(trimmed) else { return }
        // Hard cap — KVS rejects writes over 1 MB. If our payload's
        // too big (unlikely at 50 entries but possible with elaborate
        // LFO target sets), bisect down until it fits.
        var payload = data
        var count = trimmed.count
        while payload.count > 900_000 && count > 1 {
            count /= 2
            let smaller = Array(trimmed.prefix(count))
            if let smallerData = try? JSONEncoder().encode(smaller) {
                payload = smallerData
            } else { return }
        }
        let store = NSUbiquitousKeyValueStore.default
        store.set(payload, forKey: Self.kvsKey)
        store.synchronize()
    }

    /// Synchronously read the cloud preset list. Returns [] when KVS
    /// is unavailable (no entitlement, no signed-in account, no
    /// network on first launch).
    func loadFromCloud() -> [UserPreset] {
        guard let data = NSUbiquitousKeyValueStore.default.data(forKey: Self.kvsKey)
        else { return [] }
        return (try? JSONDecoder().decode([UserPreset].self, from: data)) ?? []
    }
}
