import Foundation

/// Per-LFO settings. Each oscillator holds exactly 3 LFOs.
/// Shape and target are both user-editable. depth=0 effectively disables the LFO.
struct LfoState: Equatable, Codable {
    enum Shape: String, Codable, CaseIterable, Identifiable {
        case sine, triangle, square, sampleAndHold, sawtooth, ramp
        var id: String { rawValue }
        var displayName: String {
            switch self {
            case .sine: return "Sine"
            case .triangle: return "Triangle"
            case .square: return "Square"
            case .sampleAndHold: return "S&H"
            case .sawtooth: return "Saw ↗"
            case .ramp: return "Ramp ↘"
            }
        }
        var sfSymbol: String {
            switch self {
            case .sine: return "waveform.path"
            case .triangle: return "triangle"
            case .square: return "square"
            case .sampleAndHold: return "square.split.bottomrightquarter"
            case .sawtooth: return "arrow.up.right"
            case .ramp: return "arrow.down.right"
            }
        }
    }
    enum Target: String, Codable, CaseIterable, Identifiable {
        case pan, amplitude, cutoff, pitch, filterQ, fmIndex
        var id: String { rawValue }
        var shortLabel: String {
            switch self {
            case .pan: return "pan"
            case .amplitude: return "amp"
            case .cutoff: return "cut"
            case .pitch: return "pitch"
            case .filterQ: return "Q"
            case .fmIndex: return "FM"
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

/// Stereo chorus — two short delay lines, modulated by a sine LFO whose L/R
/// phases are offset by `width × π` so the channels move in counter-phase
/// without producing a fully detuned flanger.
struct ChorusState: Equatable, Codable {
    var rateHz: Double = 0.5    // 0.05 .. 6 Hz, log
    var depth: Double  = 0.4    // 0..1 — scales the ±swing around the base 8 ms
    var width: Double  = 0.7    // 0..1 — L/R LFO phase separation (1.0 = full π)
    var mix: Double    = 0.0    // 0..1, dry/wet (default 0 = off)

    static let rateMin: Double = 0.05
    static let rateMax: Double = 6.0
    /// Base center-delay (s) the LFO modulates around.
    static let baseSec: Double = 0.008
    /// Maximum LFO swing (s) at depth=1.
    static let maxSwing: Double = 0.012

    static func defaults() -> ChorusState { ChorusState() }
}

/// Cross-oscillator FM. `sourceIndex` picks one of the OTHER three voices
/// whose raw oscillator signal modulates this voice's frequency. `index` is
/// the modulation index in Hz (peak frequency excursion at modulator amp 1.0).
struct FMState: Equatable, Codable {
    /// -1 = off; otherwise 0..3, must differ from carrier.
    var sourceIndex: Int = -1
    /// Modulation index in Hz. 0 = no modulation; 800 = bell-like.
    var index: Double = 0

    static let indexMax: Double = 800.0

    var isActive: Bool { sourceIndex >= 0 && index > 0.5 }

    static func defaults() -> FMState { FMState() }
}

/// Granular synthesis parameters — only used when waveform == .granular.
/// Each grain is a Hann-windowed slice of pink noise. The scheduler fires
/// grains at the requested density; the `jitter` knob randomizes inter-grain
/// timing (0 = clockwork, 1 = pure Poisson). `panSpread` randomizes per-grain
/// stereo placement around the voice's base pan.
struct GrainState: Equatable, Codable {
    var sizeMs: Double = 80       // 5 .. 500 ms (log)
    var densityHz: Double = 8     // 0.5 .. 50 grains/sec (log)
    var jitter: Double = 0.6      // 0 .. 1
    var panSpread: Double = 0.5   // 0 .. 1

    static let sizeMinMs: Double = 5
    static let sizeMaxMs: Double = 500
    static let densityMin: Double = 0.5
    static let densityMax: Double = 50

    static func defaults() -> GrainState { GrainState() }
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
    /// Per-voice soft-saturation drive applied to the raw oscillator/sample/
    /// noise output before the filter. 1.0 = bypass; > 1 progressively warmer.
    /// Useful for amp-style distortion (Sunn O))) / Earth) and gentle tape
    /// saturation (Basinski).
    var drive: Double = 1.0
    /// Per-voice timing envelope. Voice stays silent for `startDelaySec`
    /// after transport play, then fades in over 8 s. If `playDurationSec`
    /// > 0, the voice fades out over 8 s once it has been audible that
    /// long. 0 (default) = play immediately / play forever. Used to
    /// stagger voice introductions across a meditation or journey.
    var startDelaySec: Double = 0
    var playDurationSec: Double = 0
    var fm: FMState = .defaults()
    var chorus: ChorusState = .defaults()
    var reverb: ReverbState = .defaults()
    var delay: DelayState = .defaults()
    /// Granular synth parameters — only consumed when waveform == .granular.
    var grain: GrainState = .defaults()
    var lfos: [LfoState]    // exactly 3 — see LfoState above
    var drift: DriftVoiceConfig = .off      // per-voice drift; tick reads this directly
    var sampleName: String? = nil           // user-visible filename
    var sampleStoredFilename: String? = nil // relative path under DroneSamples/ (for preset persistence)
    /// Sample playback window — fractions of the loaded sample's length
    /// (0..1). Playback loops between `sampleStartFrac` and `sampleEndFrac`.
    /// Defaults to (0, 1) = play the whole sample. Useful for trimming a
    /// long field recording down to a sustained portion, or isolating a
    /// loop point inside a longer source.
    var sampleStartFrac: Double = 0.0
    var sampleEndFrac: Double = 1.0
    /// Crossfade seconds applied at the loop boundary — last `fadeOut` of
    /// playback before endFrac ramps down, first `fadeIn` after wrap-back
    /// ramps up. Both 0 (default) = abrupt loop point. Set to 0.5-2 s
    /// for seamless ambient loops.
    var sampleFadeInSec: Double = 0.0
    var sampleFadeOutSec: Double = 0.0

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
