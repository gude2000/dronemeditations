import Foundation

/// Per-voice drift configuration. Each oscillator stores its own copy; the
/// drift tick reads from `OscillatorState.drift` directly. Global drift
/// scenes are just templates that bulk-set this struct across all 4 voices.
struct DriftVoiceConfig: Equatable, Codable {
    enum PitchMode: String, CaseIterable, Identifiable, Codable {
        case `static`, up, down, upDown, downUp, wave, ocean, glacial
        var id: String { rawValue }
        var label: String {
            switch self {
            case .static:  return "Static"
            case .up:      return "Up 1 oct"
            case .down:    return "Down 1 oct"
            case .upDown:  return "Up / Down (^)"
            case .downUp:  return "Down / Up (V)"
            case .wave:    return "Wave (sine)"
            case .ocean:   return "Ocean (±¼ semi · 90 s)"
            case .glacial: return "Glacial wander"
            }
        }
    }
    enum PanMode: String, CaseIterable, Identifiable, Codable {
        case `static`, sweepLR, sweepRL, pendulum, antiPendulum, glacial
        var id: String { rawValue }
        var label: String {
            switch self {
            case .static:       return "Static"
            case .sweepLR:      return "Sweep L → R"
            case .sweepRL:      return "Sweep R → L"
            case .pendulum:     return "Pendulum"
            case .antiPendulum: return "Anti-pendulum"
            case .glacial:      return "Glacial wander"
            }
        }
    }
    var pitchMode: PitchMode = .static
    var pitchAmount: Double = 1.0
    var pitchPhase: Double = 0
    var panMode: PanMode = .static
    var panAmount: Double = 1.0
    var panPhase: Double = 0

    /// Custom pitch-drift amplitude in semitones (if set, overrides the
    /// default amplitude of `pitchAmount * 1 octave`). Range 0.1 – 24
    /// semitones (¼ semitone up to 2 octaves). nil = use existing
    /// pitchAmount (= 1.0 = full octave) for backward compat with
    /// presets saved before this field existed.
    var pitchSemitones: Double? = nil

    /// Custom pitch-drift period in seconds (if set, the cycle repeats
    /// every N sec using absolute time; otherwise the cycle scales to
    /// the full session length). Range 10 – 1200 sec (10s – 20 min).
    /// nil = use session-progress behavior (default for existing presets).
    var pitchPeriodSec: Double? = nil

    /// Quantize the FINAL voice pitch (drift + LFO + FM combined) to the
    /// nearest note in the current chord, spanning 2 octaves up from
    /// the voice's base frequency. Off by default — when on, smooth
    /// continuous pitch motion becomes arpeggio-like jumps between
    /// scale notes. Lets the user turn slow drift into a meditative
    /// melody, or fast LFO pitch into stepped melodic patterns.
    var quantizeToScale: Bool = false

    /// Convenience for the static (no-drift) default.
    static let off = DriftVoiceConfig()

    /// True if this voice is contributing any motion (pitch or pan).
    var isActive: Bool { pitchMode != .static || panMode != .static }
}
