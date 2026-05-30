import Foundation

/// A snapshot of the entire per-oscillator state at save time.
/// Persisted as JSON; sample audio lives separately in the Documents folder
/// and is referenced by `sampleStoredFilename`.
struct UserPreset: Identifiable, Codable, Equatable {
    let id: String
    var name: String
    let createdAt: Date

    var keyId: Int
    var octave: Int
    var chordId: String
    var tuningId: String
    var masterVolume: Double

    var oscillators: [Voice]

    /// Per-osc snapshot. Mirrors the runtime OscillatorState plus the filename
    /// of any loaded sample (relative to Documents/DroneSamples/).
    struct Voice: Codable, Equatable {
        var frequencyHz: Double
        var waveform: Waveform
        var amplitude: Double
        var pan: Double
        var isMuted: Bool
        var isSoloed: Bool
        var filter: FilterState
        var reverb: ReverbState
        var delay: DelayState
        var lfos: [LfoState]
        var sampleStoredFilename: String?
        // FX added in T5 — optional for backward compatibility with presets
        // saved before chorus + FM existed.
        var fm: FMState?
        var chorus: ChorusState?
        /// Per-voice drive (noise osc + tanh saturation), nil = no change.
        var drive: Double?
        /// Per-voice timing envelope. nil = play immediately / forever.
        var startDelaySec: Double?
        var playDurationSec: Double?
        /// Replay cycles for the timing envelope. nil = play once (the
        /// v1.0 default). 2/3/5 = repeat N times. 0 = ∞.
        var replayCount: Int?
        /// Granular settings (T14). Optional for backward compat with presets
        /// saved before the granular waveform existed.
        var grain: GrainState?
    }

    static func newId() -> String {
        "preset-\(Int(Date().timeIntervalSince1970 * 1000))-\(UUID().uuidString.prefix(6))"
    }
}
