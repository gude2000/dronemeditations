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
    }

    static func newId() -> String {
        "preset-\(Int(Date().timeIntervalSince1970 * 1000))-\(UUID().uuidString.prefix(6))"
    }
}
