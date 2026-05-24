import Foundation

enum Waveform: String, CaseIterable, Identifiable, Codable {
    case sine
    case triangle
    case sawtooth
    case square

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .sine: return "Sine"
        case .triangle: return "Triangle"
        case .sawtooth: return "Sawtooth"
        case .square: return "Square"
        }
    }

    var symbol: String {
        switch self {
        case .sine: return "waveform.path"
        case .triangle: return "triangle"
        case .sawtooth: return "scribble.variable"
        case .square: return "square"
        }
    }

    /// Sample the waveform at a normalized phase in [0, 1).
    /// Returns a value in [-1, 1].
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
        }
    }
}
