import Foundation

/// A single-oscillator preset — captures everything about one voice (freq,
/// waveform, pan, amplitude, filter, reverb, delay, all LFOs, drift) so the
/// user can save favorite voice sounds and load them into any slot.
/// Persistence is JSON in UserDefaults, keyed by `Self.storageKey`.
struct VoicePreset: Codable, Identifiable {
    let id: String
    var name: String
    let createdAt: Date
    let voice: VoiceSnapshot

    struct VoiceSnapshot: Codable {
        var frequencyHz: Double
        var waveform: Waveform
        var amplitude: Double
        var pan: Double
        var filter: FilterState
        var reverb: ReverbState
        var delay: DelayState
        var lfos: [LfoState]
        var drift: DriftVoiceConfig
        // FX added in T5 — optional for backward compatibility with voice
        // presets saved before chorus + FM existed. nil → defaults on load.
        var fm: FMState?
        var chorus: ChorusState?
        var drive: Double?
        var startDelaySec: Double?
        var playDurationSec: Double?
    }
}

// MARK: - Storage

enum VoicePresetStore {
    private static let key = "dronemeditations.voicePresets"

    static func load() -> [VoicePreset] {
        guard let data = UserDefaults.standard.data(forKey: key) else { return [] }
        return (try? JSONDecoder().decode([VoicePreset].self, from: data)) ?? []
    }

    static func save(_ list: [VoicePreset]) {
        guard let data = try? JSONEncoder().encode(list) else { return }
        UserDefaults.standard.set(data, forKey: key)
    }
}
