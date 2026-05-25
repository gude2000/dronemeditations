import Foundation

enum Waveform: String, CaseIterable, Identifiable, Codable {
    case sine
    case triangle
    case sawtooth
    case square
    case whiteNoise   // flat-spectrum noise — tape hiss, wind, breath
    case pinkNoise    // 1/f noise — surf, rain, "warmer" hiss
    case sample       // plays a user-loaded audio file; frequency acts as pitch shift

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .sine: return "Sine"
        case .triangle: return "Triangle"
        case .sawtooth: return "Sawtooth"
        case .square: return "Square"
        case .whiteNoise: return "White Noise"
        case .pinkNoise: return "Pink Noise"
        case .sample: return "Sample"
        }
    }

    var symbol: String {
        switch self {
        case .sine: return "waveform.path"
        case .triangle: return "triangle"
        case .sawtooth: return "scribble.variable"
        case .square: return "square"
        case .whiteNoise: return "dot.radiowaves.left.and.right"
        case .pinkNoise: return "wind"
        case .sample: return "waveform"
        }
    }

    /// True when this waveform is a stochastic noise source (not periodic).
    /// Voice.render uses this to skip phase math and pull samples from its
    /// noise generator instead.
    var isNoise: Bool {
        switch self {
        case .whiteNoise, .pinkNoise: return true
        default: return false
        }
    }

    /// Sample the waveform at a normalized phase in [0, 1).
    /// Returns a value in [-1, 1]. Noise + sample variants return 0 here —
    /// Voice reads its noise generator / buffer directly.
    @inline(__always)
    func sample(phase: Double) -> Double {
        switch self {
        case .sine:
            return sin(phase * 2.0 * .pi)
        case .triangle:
            let p = phase
            return p < 0.5 ? (4.0 * p - 1.0) : (3.0 - 4.0 * p)
        case .sawtooth:
            return 2.0 * phase - 1.0
        case .square:
            return phase < 0.5 ? 1.0 : -1.0
        case .whiteNoise, .pinkNoise, .sample:
            return 0
        }
    }
}
