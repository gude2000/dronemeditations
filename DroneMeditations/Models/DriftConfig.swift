import Foundation

/// Per-voice drift configuration. Each oscillator stores its own copy; the
/// drift tick reads from `OscillatorState.drift` directly. Global drift
/// scenes are just templates that bulk-set this struct across all 4 voices.
struct DriftVoiceConfig: Equatable, Codable {
    enum PitchMode: String, CaseIterable, Identifiable, Codable {
        case `static`, up, down, upDown, downUp, wave, glacial
        var id: String { rawValue }
        var label: String {
            switch self {
            case .static:  return "Static"
            case .up:      return "Up 1 oct"
            case .down:    return "Down 1 oct"
            case .upDown:  return "Up / Down (^)"
            case .downUp:  return "Down / Up (V)"
            case .wave:    return "Wave (sine)"
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

    /// Convenience for the static (no-drift) default.
    static let off = DriftVoiceConfig()

    /// True if this voice is contributing any motion (pitch or pan).
    var isActive: Bool { pitchMode != .static || panMode != .static }
}
