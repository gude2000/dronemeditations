import Foundation

/// Per-LFO settings. Each oscillator holds exactly 3 LFOs.
/// Shape and target are both user-editable. depth=0 effectively disables the LFO.
struct LfoState: Equatable, Codable {
    enum Shape: String, Codable, CaseIterable, Identifiable {
        case sine, triangle, square, sampleAndHold
        var id: String { rawValue }
        var displayName: String {
            switch self {
            case .sine: return "Sine"
            case .triangle: return "Triangle"
            case .square: return "Square"
            case .sampleAndHold: return "S&H"
            }
        }
        var sfSymbol: String {
            switch self {
            case .sine: return "waveform.path"
            case .triangle: return "triangle"
            case .square: return "square"
            case .sampleAndHold: return "square.split.bottomrightquarter"
            }
        }
    }
    enum Target: String, Codable, CaseIterable, Identifiable {
        case pan, amplitude, cutoff, pitch
        var id: String { rawValue }
        var shortLabel: String {
            switch self {
            case .pan: return "pan"
            case .amplitude: return "amp"
            case .cutoff: return "cut"
            case .pitch: return "pitch"
            }
        }
    }

    var shape: Shape
    var target: Target
    var rateHz: Double  // 0.02..8 (log slider)
    var depth: Double   // 0..1

    static let rateMin: Double = 0.02
    static let rateMax: Double = 8.0

    static func defaults() -> [LfoState] {
        [
            LfoState(shape: .sine,          target: .pan,       rateHz: 0.25, depth: 0),
            LfoState(shape: .sampleAndHold, target: .amplitude, rateHz: 0.50, depth: 0),
            LfoState(shape: .sine,          target: .cutoff,    rateHz: 0.30, depth: 0),
            LfoState(shape: .sine,          target: .pitch,     rateHz: 0.30, depth: 0)
        ]
    }
}

/// Per-oscillator reverb (Schroeder design, medium-long decay range).
struct ReverbState: Equatable, Codable {
    var decaySec: Double = 2.0   // 0.1 .. 10
    var mix: Double = 0.0        // 0..1, dry/wet level

    static let decayMin: Double = 0.1
    static let decayMax: Double = 10.0

    static func defaults() -> ReverbState {
        ReverbState(decaySec: 2.0, mix: 0)
    }
}

/// Per-oscillator delay line with feedback.
struct DelayState: Equatable, Codable {
    enum Mode: String, CaseIterable, Identifiable, Codable {
        case mono, stereo, pingPong
        var id: String { rawValue }
        var label: String {
            switch self {
            case .mono:     return "Mono"
            case .stereo:   return "Stereo"
            case .pingPong: return "Ping-Pong"
            }
        }
    }
    /// Musical-division timing labels. `free` lets the user drag the time
    /// slider; the others compute timeSec from the global tempo.
    enum Timing: String, CaseIterable, Identifiable, Codable {
        case free, half = "1/2", third = "1/3", thirdT = "1/3t",
             quarter = "1/4", quarterT = "1/4t",
             eighth = "1/8", eighthT = "1/8t",
             sixteenth = "1/16", sixteenthT = "1/16t"
        var id: String { rawValue }
        var label: String {
            switch self {
            case .free: return "Free"
            case .half: return "1/2"
            case .third: return "1/3"
            case .thirdT: return "1/3T"
            case .quarter: return "1/4"
            case .quarterT: return "1/4T"
            case .eighth: return "1/8"
            case .eighthT: return "1/8T"
            case .sixteenth: return "1/16"
            case .sixteenthT: return "1/16T"
            }
        }
        /// Beats per bar at 4/4. nil for `free`.
        var beats: Double? {
            switch self {
            case .free: return nil
            case .half: return 2.0
            case .third: return 4.0 / 3.0
            case .thirdT: return 8.0 / 9.0
            case .quarter: return 1.0
            case .quarterT: return 2.0 / 3.0
            case .eighth: return 0.5
            case .eighthT: return 1.0 / 3.0
            case .sixteenth: return 0.25
            case .sixteenthT: return 1.0 / 6.0
            }
        }
        /// Seconds for one tap at the given BPM. nil for `free`.
        func seconds(bpm: Double = 120) -> Double? {
            guard let b = beats else { return nil }
            return b * 60.0 / bpm
        }
    }

    var timeSec: Double = 0.30   // 0.02 .. 2.0
    var feedback: Double = 0.40  // 0 .. 0.95
    var mix: Double = 0.0        // 0..1, dry/wet level
    var mode: Mode = .mono
    var timing: Timing = .free

    static let timeMin: Double = 0.02
    static let timeMax: Double = 2.0
    static let feedbackMax: Double = 0.95

    static func defaults() -> DelayState {
        DelayState(timeSec: 0.30, feedback: 0.40, mix: 0, mode: .mono, timing: .free)
    }
}

/// Per-oscillator biquad filter. Type LP/HP/BP. Modulatable via an LFO targeting `cutoff`.
struct FilterState: Equatable, Codable {
    enum FilterType: String, Codable, CaseIterable, Identifiable {
        case lowpass, highpass, bandpass
        var id: String { rawValue }
        var shortLabel: String {
            switch self {
            case .lowpass: return "LP"
            case .highpass: return "HP"
            case .bandpass: return "BP"
            }
        }
    }
    var type: FilterType
    var cutoffHz: Double  // 20..8000
    var q: Double         // 0.3..20

    static let cutoffMin: Double = 20
    static let cutoffMax: Double = 8000
    static let qMin: Double = 0.3
    static let qMax: Double = 20

    static func defaults() -> FilterState {
        FilterState(type: .lowpass, cutoffHz: 4000, q: 0.7)
    }
}

/// Observable per-oscillator settings. The audio engine reads its own atomic-ish backing
/// store; this struct drives the UI and pushes changes into the engine.
struct OscillatorState: Identifiable, Equatable {
    let id: Int  // 0..3
    var frequencyHz: Double
    var waveform: Waveform
    var amplitude: Double   // 0..1 — voice gain before mute/solo
    var pan: Double         // -1 (L) .. +1 (R)
    var isMuted: Bool
    var isSoloed: Bool
    var filter: FilterState
    var reverb: ReverbState = .defaults()
    var delay: DelayState = .defaults()
    var lfos: [LfoState]    // exactly 3 — see LfoState above
    var drift: DriftVoiceConfig = .off      // per-voice drift; tick reads this directly
    var sampleName: String? = nil           // user-visible filename
    var sampleStoredFilename: String? = nil // relative path under DroneSamples/ (for preset persistence)

    static let minFrequency: Double = 20.0
    static let maxFrequency: Double = 2000.0

    static func defaults() -> [OscillatorState] {
        return [
            OscillatorState(id: 0, frequencyHz: 110.0, waveform: .sine,
                            amplitude: 0.6, pan: -0.3, isMuted: false, isSoloed: false,
                            filter: FilterState.defaults(),
                            lfos: LfoState.defaults()),
            OscillatorState(id: 1, frequencyHz: 165.0, waveform: .sine,
                            amplitude: 0.6, pan: 0.1, isMuted: false, isSoloed: false,
                            filter: FilterState.defaults(),
                            lfos: LfoState.defaults()),
            OscillatorState(id: 2, frequencyHz: 220.0, waveform: .sine,
                            amplitude: 0.55, pan: -0.1, isMuted: false, isSoloed: false,
                            filter: FilterState.defaults(),
                            lfos: LfoState.defaults()),
            OscillatorState(id: 3, frequencyHz: 277.18, waveform: .sine,
                            amplitude: 0.5, pan: 0.3, isMuted: false, isSoloed: false,
                            filter: FilterState.defaults(),
                            lfos: LfoState.defaults())
        ]
    }

    /// Color band for visualizations (low/mid/high frequencies map to different hues).
    var hue: Double {
        let logF = log2(max(frequencyHz, 20.0))
        let lo = log2(20.0)       // ~4.32
        let hi = log2(2000.0)     // ~10.97
        let t = (logF - lo) / (hi - lo)
        // Map low freq -> warm (0.05), high freq -> cool (0.65)
        return 0.05 + (0.6 * t)
    }
}
