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
        /// v1 diagnostic: carries the underlying DecodingError so the import
        /// alert can show what field / type mismatch actually broke the
        /// decode. Keeps `.decodeFailed` for non-diagnostic call sites.
        case decodeFailedDetail(String)
        case unsupportedVersion(Int)

        var errorDescription: String? {
            switch self {
            case .readFailed:            return "Couldn't read the preset file."
            case .decodeFailed:          return "Preset file is malformed or not a Drone Meditations preset."
            case .decodeFailedDetail(let d): return "Decode failed: \(d)"
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

        guard let rawOrig = try? Data(contentsOf: url) else { throw ImportError.readFailed }
        // v1 cross-platform translation pass. The web app uses
        // shorthand enum strings for LFO shape + target ("sh", "amp",
        // "q", "fm") where iOS expects the canonical Swift enum case
        // names ("sampleAndHold", "amplitude", "filterQ", "fmIndex").
        // Walk the JSON dictionary, rewrite those values in place,
        // then re-serialize for the strongly-typed decoder. Lossless
        // for iOS-shaped envelopes — translateWebEnumStrings is a
        // no-op when the strings are already canonical.
        let raw = translateWebEnumStrings(in: rawOrig) ?? rawOrig
        let env: Envelope
        do {
            // v1 cross-platform: the web app exports `createdAt` as an
            // ISO 8601 string (new Date().toISOString()), but Swift's
            // default Codable Date strategy expects a Double of
            // timeIntervalSinceReferenceDate. Install a lenient decoder
            // that accepts all three shapes we might see in the wild:
            //   • ISO 8601 string  → web export
            //   • Double < 1e10     → iOS native (seconds since 2001)
            //   • Double ≥ 1e10     → JS Date.now() (ms since 1970)
            // This lets a preset move between web and iOS in either
            // direction without losing the original save timestamp.
            env = try JSONDecoder.dronepresetLenient.decode(Envelope.self, from: raw)
        } catch let DecodingError.keyNotFound(key, ctx) {
            let path = ctx.codingPath.map { $0.stringValue }.joined(separator: ".")
            throw ImportError.decodeFailedDetail("missing key '\(key.stringValue)' at \(path.isEmpty ? "<root>" : path)")
        } catch let DecodingError.typeMismatch(type, ctx) {
            let path = ctx.codingPath.map { $0.stringValue }.joined(separator: ".")
            throw ImportError.decodeFailedDetail("type mismatch \(type) at \(path.isEmpty ? "<root>" : path)")
        } catch let DecodingError.valueNotFound(type, ctx) {
            let path = ctx.codingPath.map { $0.stringValue }.joined(separator: ".")
            throw ImportError.decodeFailedDetail("value not found \(type) at \(path.isEmpty ? "<root>" : path)")
        } catch let DecodingError.dataCorrupted(ctx) {
            let path = ctx.codingPath.map { $0.stringValue }.joined(separator: ".")
            throw ImportError.decodeFailedDetail("data corrupted at \(path.isEmpty ? "<root>" : path): \(ctx.debugDescription)")
        } catch {
            throw ImportError.decodeFailedDetail(error.localizedDescription)
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

    /// Walk a `.dronepreset` JSON dictionary and rewrite the parts of
    /// the web schema that need shape-translation before the strongly
    /// typed iOS decoder will accept it. Two passes:
    ///
    /// 1. LFO enum string shorthand
    ///      • shape  "sh"  → "sampleAndHold"
    ///      • target "amp" → "amplitude"
    ///      • target "q"   → "filterQ"
    ///      • target "fm"  → "fmIndex"
    ///    (sine / triangle / square / sawtooth / ramp + pan / cutoff /
    ///     pitch are byte-identical already.)
    ///
    /// 2. Sample reference shape
    ///    Web voices store samples as `sampleRef: { id, name }` where
    ///    id is an IndexedDB key like "sample-mb8x9d-a3f4k2" — no file
    ///    extension. iOS voices store `sampleStoredFilename: String?`
    ///    pointing at a real file in Documents/DroneSamples/, and
    ///    AVAudioFile relies on a recognizable extension. So we:
    ///      • Append `.wav` (or the right ext for the mime type) to
    ///        every samples[i].filename that doesn't already carry an
    ///        extension. AVAudioFile then sniffs correctly when the
    ///        bytes hit disk during import.
    ///      • For each voice that has sampleRef.id but no
    ///        sampleStoredFilename, write the translated filename into
    ///        sampleStoredFilename so the decoded UserPreset.Voice
    ///        ends up pointing at the same file we just wrote.
    ///
    /// Iceberg-safe: any field that doesn't match the patterns above
    /// passes through verbatim, so iOS-saved envelopes stay
    /// byte-identical. Returns nil if the JSON isn't a top-level
    /// object; the caller will then try to decode the original bytes
    /// and let the user see the resulting error.
    fileprivate static func translateWebEnumStrings(in data: Data) -> Data? {
        guard var root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            return nil
        }
        let shapeMap: [String: String] = ["sh": "sampleAndHold"]
        let targetMap: [String: String] = ["amp": "amplitude", "q": "filterQ", "fm": "fmIndex"]

        // Pass 1 — rename embedded sample files so they carry a real
        // extension. Map oldId → newFilename so step 2 below can patch
        // each voice that referenced this sample.
        var sampleIdRename: [String: String] = [:]
        if var samples = root["samples"] as? [[String: Any]] {
            for i in 0..<samples.count {
                guard let oldName = samples[i]["filename"] as? String else { continue }
                if !(oldName as NSString).pathExtension.isEmpty {
                    // Already has an extension — assume it works.
                    sampleIdRename[oldName] = oldName
                    continue
                }
                let mime = (samples[i]["mime"] as? String)?.lowercased() ?? "audio/wav"
                let ext: String
                switch mime {
                case "audio/wav", "audio/wave", "audio/x-wav":           ext = "wav"
                case "audio/mpeg", "audio/mp3":                          ext = "mp3"
                case "audio/mp4", "audio/aac", "audio/x-m4a", "audio/m4a": ext = "m4a"
                case "audio/ogg", "audio/webm":                          ext = "ogg"
                case "audio/flac":                                       ext = "flac"
                default:                                                 ext = "wav"
                }
                let newName = "\(oldName).\(ext)"
                samples[i]["filename"] = newName
                sampleIdRename[oldName] = newName
            }
            root["samples"] = samples
        }

        // Pass 2 — walk voices: LFO enum strings + sampleRef → sampleStoredFilename.
        if var preset = root["preset"] as? [String: Any],
           var oscs = preset["oscillators"] as? [[String: Any]] {
            for i in 0..<oscs.count {
                var voice = oscs[i]

                // 2a — LFO enum strings.
                if var lfos = voice["lfos"] as? [[String: Any]] {
                    for j in 0..<lfos.count {
                        if let shape = lfos[j]["shape"] as? String, let mapped = shapeMap[shape] {
                            lfos[j]["shape"] = mapped
                        }
                        if let target = lfos[j]["target"] as? String, let mapped = targetMap[target] {
                            lfos[j]["target"] = mapped
                        }
                        // v1 fix: defensively scrub the targets array.
                        // Some web-exported presets carry `null` (or
                        // other non-string sentinels) inside targets —
                        // observed in user file "JG Dub Wave" at
                        // oscillators[1].lfos[0].targets[0]. The strict
                        // iOS decoder rejects the whole envelope with
                        // "value not found String at ...". Walk the
                        // array element-by-element, compact away
                        // anything that isn't a string, then apply the
                        // shorthand map. Empty result is fine — Voice's
                        // custom decoder accepts an empty `targets`
                        // set, and falls back to the singular `target`
                        // field below if present.
                        if let targets = lfos[j]["targets"] as? [Any] {
                            let cleaned: [String] = targets.compactMap { el -> String? in
                                guard let s = el as? String else { return nil }
                                return targetMap[s] ?? s
                            }
                            lfos[j]["targets"] = cleaned
                        }
                    }
                    voice["lfos"] = lfos
                }

                // 2b — sampleRef → sampleStoredFilename.
                // Only set if the iOS-style field is missing so an iOS
                // export that happens to also carry sampleRef (defensive
                // future-compat) doesn't get double-translated.
                if voice["sampleStoredFilename"] is NSNull || voice["sampleStoredFilename"] == nil {
                    if let ref = voice["sampleRef"] as? [String: Any],
                       let id = ref["id"] as? String {
                        voice["sampleStoredFilename"] = sampleIdRename[id] ?? id
                    }
                }

                oscs[i] = voice
            }
            preset["oscillators"] = oscs
            root["preset"] = preset
        }
        return try? JSONSerialization.data(withJSONObject: root)
    }

    /// Lenient JSONDecoder used for `.dronepreset` imports. Tolerates
    /// the three `createdAt` shapes we see in the wild:
    ///   • ISO 8601 string  — web app (`new Date().toISOString()`)
    ///   • Double < 1e10    — iOS native (`timeIntervalSinceReferenceDate`)
    ///   • Double ≥ 1e10    — JS `Date.now()` (ms since 1970)
    /// Used only on the import path — internal save/load on disk
    /// stays on the default strategy.
    fileprivate static let importDateStrategy: JSONDecoder.DateDecodingStrategy = {
        let isoFractional = ISO8601DateFormatter()
        isoFractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let isoPlain = ISO8601DateFormatter()
        isoPlain.formatOptions = [.withInternetDateTime]
        return .custom { decoder in
            let c = try decoder.singleValueContainer()
            if let s = try? c.decode(String.self) {
                if let d = isoFractional.date(from: s) { return d }
                if let d = isoPlain.date(from: s) { return d }
                throw DecodingError.dataCorruptedError(in: c,
                    debugDescription: "Unrecognized date string: \(s)")
            }
            if let n = try? c.decode(Double.self) {
                if n >= 1e10 {  // Date.now() ms since 1970
                    return Date(timeIntervalSince1970: n / 1000.0)
                }
                return Date(timeIntervalSinceReferenceDate: n)  // Swift native
            }
            throw DecodingError.dataCorruptedError(in: c,
                debugDescription: "Date is neither a string nor a number")
        }
    }()

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
    /// Tombstone set — preset ids the user deleted. Without this, the
    /// additive merge in pushSync re-appends a just-deleted preset from
    /// the cloud copy, so it resurrects on next launch. Tombstones are
    /// stored both in cloud (so deletes propagate to paired devices) and
    /// in local UserDefaults (so a delete survives relaunch even before
    /// the cloud round-trips).
    private static let tombstoneKvsKey = "userPresetTombstones"
    private static let tombstoneDefaultsKey = "userPresetTombstones.local"
    /// Cap on entries we mirror. KVS limit is 1 MB total per app and
    /// presets aren't tiny (LFO arrays, drift config, all FX state).
    /// 50 keeps us well inside the budget and still covers active
    /// users — heavy users routinely sit at 20-30 saved presets.
    private static let maxPresets = 50
    /// Cap tombstones too — old deletions don't need to live forever.
    /// Once a deleted id has aged out of every device's cloud preset
    /// list there's nothing left to resurrect, so a generous cap is safe.
    private static let maxTombstones = 200

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
    ///
    /// v1 perf: deferred off the calling actor so the JSON-encode +
    /// UserDefaults.set + NSUbiquitousKeyValueStore.synchronize chain
    /// (which can spike 100–300 ms on iPhone with many presets) doesn't
    /// block the main thread right as the user taps Save. The user sees
    /// the sheet dismiss instantly; the cloud mirror catches up in the
    /// background a beat later.
    func push(_ local: [UserPreset]) {
        Task.detached(priority: .utility) {
            await self.pushSync(local)
        }
    }

    private func pushSync(_ local: [UserPreset]) async {
        let cloud = loadFromCloudRaw()
        let tombstones = currentTombstones()
        // Local wins on collision (user just edited / saved that id).
        var merged = local.filter { !tombstones.contains($0.id) }
        let localIds = Set(merged.map(\.id))
        // Re-include only cloud presets that are NOT in local AND NOT
        // tombstoned. A just-deleted preset is in cloud but tombstoned,
        // so it stays dropped — fixing the "deleted preset resurrects on
        // relaunch" bug.
        for cp in cloud where !localIds.contains(cp.id) && !tombstones.contains(cp.id) {
            merged.append(cp)
        }
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
        // Mirror the merged tombstone set to cloud so deletions propagate.
        if let tData = try? JSONEncoder().encode(Array(tombstones.prefix(Self.maxTombstones))) {
            store.set(tData, forKey: Self.tombstoneKvsKey)
        }
        store.synchronize()
    }

    /// Record a deletion. Adds the id to the local tombstone set (persisted
    /// immediately so it survives relaunch) and mirrors the merged set to
    /// cloud. Call from DroneViewModel.deleteUserPreset BEFORE the push.
    func recordDeletion(ids: [String]) {
        guard !ids.isEmpty else { return }
        var t = currentTombstones()
        for id in ids { t.insert(id) }
        saveLocalTombstones(t)
        let store = NSUbiquitousKeyValueStore.default
        if let tData = try? JSONEncoder().encode(Array(t.prefix(Self.maxTombstones))) {
            store.set(tData, forKey: Self.tombstoneKvsKey)
            store.synchronize()
        }
    }

    /// The set of deleted ids the consumer should suppress when merging
    /// incoming cloud presets, exposed so DroneViewModel.mergeCloudPresets
    /// can also drop any LOCAL preset that another device tombstoned.
    func deletedIds() -> Set<String> { currentTombstones() }

    /// Cloud preset list with tombstoned entries filtered out. This is
    /// what callers should use — a deleted preset never surfaces here.
    func loadFromCloud() -> [UserPreset] {
        let tombstones = currentTombstones()
        return loadFromCloudRaw().filter { !tombstones.contains($0.id) }
    }

    /// Unfiltered cloud read. Internal — only pushSync needs the raw list
    /// (it applies tombstone filtering itself with the merged set).
    private func loadFromCloudRaw() -> [UserPreset] {
        guard let data = NSUbiquitousKeyValueStore.default.data(forKey: Self.kvsKey)
        else { return [] }
        return (try? JSONDecoder().decode([UserPreset].self, from: data)) ?? []
    }

    // MARK: - Tombstone storage

    /// Union of local (UserDefaults) + cloud (KVS) tombstones.
    private func currentTombstones() -> Set<String> {
        var t = loadLocalTombstones()
        if let data = NSUbiquitousKeyValueStore.default.data(forKey: Self.tombstoneKvsKey),
           let cloudIds = try? JSONDecoder().decode([String].self, from: data) {
            t.formUnion(cloudIds)
        }
        return t
    }

    private func loadLocalTombstones() -> Set<String> {
        let arr = UserDefaults.standard.stringArray(forKey: Self.tombstoneDefaultsKey) ?? []
        return Set(arr)
    }

    private func saveLocalTombstones(_ t: Set<String>) {
        UserDefaults.standard.set(Array(t.prefix(Self.maxTombstones)),
                                  forKey: Self.tombstoneDefaultsKey)
    }
}

// v1: helper used by UserPresetSharing.importPreset for cross-platform
// `.dronepreset` decode. Centralizes the lenient date strategy so the
// import call site stays compact and any future cross-platform tweaks
// (e.g. handling a Date.now()-ms field elsewhere in the schema) have
// a single place to land.
extension JSONDecoder {
    static var dronepresetLenient: JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = UserPresetSharing.importDateStrategy
        return d
    }
}
