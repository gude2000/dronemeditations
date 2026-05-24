import Foundation

/// A single oscillator voice owned by the audio engine.
///
/// Setters are called from the UI thread and write directly to primitive properties; the
/// audio render thread reads them. Single-word aligned writes (Double/Float/Bool) are
/// tear-free on Apple Silicon and 64-bit ARM iOS, so this is safe without locks for the
/// per-sample read pattern below. Parameter ramps in the render block guarantee no clicks
/// when UI values change.
final class Voice {
    let id: Int
    let sampleRate: Double

    // UI-writable targets
    var targetFrequencyHz: Double = 220.0
    var targetAmplitude: Float = 0.6
    var targetPan: Float = 0.0          // -1 L .. +1 R
    var waveform: Waveform = .sine
    var isMuted: Bool = false
    var isSoloed: Bool = false

    /// Engine-computed each render buffer: true if this voice should actually sound
    /// after applying the global solo rule.
    var effectiveEnabled: Bool = true

    // 3 LFOs with user-editable shape + target. Mirror of LfoState.
    var lfoShapes: [LfoState.Shape]   = [.sine, .sampleAndHold, .sine]
    var lfoTargets: [LfoState.Target] = [.pan, .amplitude, .cutoff]
    var lfoRatesHz: [Double]          = [0.25, 0.50, 0.30]
    var lfoDepths: [Double]           = [0.0, 0.0, 0.0]
    private var lfoPhases: [Double]   = [0.0, 0.0, 0.0]
    private var lfoHolds: [Double]    = [0.0, 0.0, 0.0]

    // Biquad filter (LP / HP / BP). UI-writable targets + coefficients computed per render.
    var filterType: FilterState.FilterType = .lowpass
    var filterCutoffHz: Double = 4000.0
    var filterQ: Double = 0.7

    private var bqB0: Double = 1.0
    private var bqB1: Double = 0.0
    private var bqB2: Double = 0.0
    private var bqA1: Double = 0.0
    private var bqA2: Double = 0.0
    private var bqS1: Double = 0.0
    private var bqS2: Double = 0.0

    // Loaded sample buffer (mono float, -1..1) + native sample rate.
    var sampleData: [Float]? = nil
    var sampleNativeRate: Double = 44100
    private var samplePosition: Double = 0

    // Reverb (Schroeder JCRev: 4 parallel combs + 2 series allpasses).
    var reverbDecaySec: Double = 2.0
    var reverbMix: Float = 0.0
    private static let combLengths: [Int] = [1116, 1188, 1277, 1356]
    private static let allpassLengths: [Int] = [556, 441]
    private static let allpassFb: Double = 0.5
    private var combBuffers: [[Float]] = []
    private var combWriteIdx: [Int] = [0, 0, 0, 0]
    private var combFb: [Double]      = [0, 0, 0, 0]
    private var allpassBuffers: [[Float]] = []
    private var allpassWriteIdx: [Int] = [0, 0]

    // Delay (circular buffer with feedback).
    var delayTimeSec: Double = 0.30
    var delayFeedback: Float = 0.40
    var delayMix: Float = 0.0
    private var delayBuffer: [Float] = []
    private var delayBufferSize: Int = 0
    private var delayWriteIdx: Int = 0

    // Render-thread state
    private var phase: Double = 0.0
    private var currentFreq: Double = 220.0
    private var currentAmp: Float = 0.0
    private var currentPan: Float = 0.0

    // Slew constants (computed once at init from sample rate).
    private let freqSlewPerSample: Double
    private let ampSlewPerSample: Float
    private let panSlewPerSample: Float

    init(id: Int, sampleRate: Double) {
        self.id = id
        self.sampleRate = sampleRate
        // ~20ms freq slew, ~10ms amp/pan slew — long enough to avoid zipper noise,
        // short enough that gestures feel responsive.
        let freqMs = 0.020
        let levelMs = 0.010
        self.freqSlewPerSample = 1.0 / (freqMs * sampleRate)
        self.ampSlewPerSample = Float(1.0 / (levelMs * sampleRate))
        self.panSlewPerSample = Float(1.0 / (levelMs * sampleRate))

        // Allocate reverb + delay buffers.
        self.combBuffers = Voice.combLengths.map { Array(repeating: 0, count: $0) }
        self.allpassBuffers = Voice.allpassLengths.map { Array(repeating: 0, count: $0) }
        self.delayBufferSize = Int(sampleRate * 2.0)
        self.delayBuffer = Array(repeating: 0, count: delayBufferSize)
    }

    /// Render `frameCount` stereo samples, summing into `left` and `right` (output is additive).
    @inline(__always)
    func render(frameCount: Int, left: UnsafeMutablePointer<Float>, right: UnsafeMutablePointer<Float>) {
        let targetFreq = targetFrequencyHz
        // If solo/mute disables this voice, ramp amp toward 0 instead of cutting hard.
        let baseAmp: Float = effectiveEnabled && !isMuted ? targetAmplitude : 0
        let basePan: Float = targetPan
        let wave = waveform

        // ── Advance LFOs once per buffer and dispatch by target.
        let bufferSeconds = Double(frameCount) / sampleRate
        var panMod: Double = 0
        var ampScale: Double = 1.0
        var cutoffOct: Double = 0
        for k in 0..<3 {
            let depth = lfoDepths[k]
            if depth < 0.001 { continue }
            lfoPhases[k] += lfoRatesHz[k] * bufferSeconds
            var stepped = false
            if lfoPhases[k] >= 1.0 {
                lfoPhases[k] -= floor(lfoPhases[k])
                stepped = true
            }
            let value: Double
            switch lfoShapes[k] {
            case .sine:
                value = sin(lfoPhases[k] * 2.0 * .pi)
            case .square:
                value = lfoPhases[k] < 0.5 ? 1.0 : -1.0
            case .sampleAndHold:
                if stepped || lfoHolds[k] == 0 {
                    lfoHolds[k] = Double.random(in: -1.0 ... 1.0)
                }
                value = lfoHolds[k]
            }
            switch lfoTargets[k] {
            case .pan:       panMod    += depth * value
            case .amplitude: ampScale  *= (1.0 + 0.6 * depth * value)
            case .cutoff:    cutoffOct += 2.0 * depth * value
            }
        }

        let panTarget = Float(max(-1.0, min(1.0, Double(basePan) + panMod)))
        let ampTarget = Float(max(0.0, min(1.0, Double(baseAmp) * ampScale)))

        // ── Update biquad coefficients with LFO-modulated cutoff.
        let effectiveCutoff = filterCutoffHz * pow(2.0, cutoffOct)
        updateBiquadCoefficients(cutoff: effectiveCutoff)

        // ── Recompute reverb comb feedbacks (cheap, once per buffer).
        let ln10x3 = 3.0 * 2.302585092994046
        for k in 0..<4 {
            combFb[k] = exp(-ln10x3 * Double(Voice.combLengths[k]) / (sampleRate * max(0.1, reverbDecaySec)))
        }
        // Resolve delay tap length in samples.
        let delayTapSamples = max(1, min(delayBufferSize - 1, Int(delayTimeSec * sampleRate)))
        let revMix = reverbMix
        let dlyMix = delayMix
        let dlyFb = delayFeedback

        let invSR = 1.0 / sampleRate

        var ph = phase
        var f = currentFreq
        var a = currentAmp
        var p = currentPan

        // One-pole exponential smoothing (per-sample weight).
        let fStep = freqSlewPerSample
        let aStep = Double(ampSlewPerSample)
        let pStep = Double(panSlewPerSample)

        // For sample mode: precompute per-buffer pitch ratio + sample-frame increment.
        // 220 Hz = unity playback; chord intervals translate to pitch shifts of the sample.
        let isSampleMode = (wave == .sample) && (sampleData?.isEmpty == false)
        let sampleIncrement: Double = isSampleMode
            ? max(0.05, min(20.0, targetFreq / 220.0)) * (sampleNativeRate / sampleRate)
            : 0
        // Snapshot the array's storage pointer outside the loop to avoid per-sample ARC.
        let sampleCount = sampleData?.count ?? 0

        for i in 0..<frameCount {
            f += (targetFreq - f) * fStep
            a += Float((Double(ampTarget) - Double(a)) * aStep)
            p += Float((Double(panTarget) - Double(p)) * pStep)

            let raw: Double
            if isSampleMode, sampleCount > 0 {
                let pos = samplePosition
                let i0 = Int(pos) % sampleCount
                let i1 = (i0 + 1) % sampleCount
                let frac = pos - floor(pos)
                let s0 = Double(sampleData![i0])
                let s1 = Double(sampleData![i1])
                raw = s0 * (1.0 - frac) + s1 * frac
                samplePosition += sampleIncrement
                if samplePosition >= Double(sampleCount) {
                    samplePosition -= Double(sampleCount)
                }
            } else {
                // Synth oscillator: advance phase + sample the waveform formula.
                ph += f * invSR
                if ph >= 1.0 { ph -= floor(ph) }
                raw = wave.sample(phase: ph)
            }

            // Biquad Direct Form II Transposed.
            let y = bqB0 * raw + bqS1
            bqS1 = bqB1 * raw - bqA1 * y + bqS2
            bqS2 = bqB2 * raw - bqA2 * y
            let fxIn = Float(y) * a

            // ── Reverb (Schroeder JCRev): 4 parallel combs + 2 series allpasses.
            var combSum: Double = 0
            for k in 0..<4 {
                let bufLen = Voice.combLengths[k]
                var wIdx = combWriteIdx[k]
                let combOut = combBuffers[k][wIdx]
                combSum += Double(combOut)
                combBuffers[k][wIdx] = Float(Double(fxIn) + Double(combOut) * combFb[k])
                wIdx += 1; if wIdx >= bufLen { wIdx = 0 }
                combWriteIdx[k] = wIdx
            }
            var ap = combSum * 0.25
            for k in 0..<2 {
                let bufLen = Voice.allpassLengths[k]
                var wIdx = allpassWriteIdx[k]
                let bufOut = Double(allpassBuffers[k][wIdx])
                let result = -ap + bufOut
                allpassBuffers[k][wIdx] = Float(ap + bufOut * Voice.allpassFb)
                wIdx += 1; if wIdx >= bufLen { wIdx = 0 }
                allpassWriteIdx[k] = wIdx
                ap = result
            }
            let revWet = Float(ap)

            // ── Delay (circular buffer + feedback).
            var rIdx = delayWriteIdx - delayTapSamples
            if rIdx < 0 { rIdx += delayBufferSize }
            let delayOut = delayBuffer[rIdx]
            delayBuffer[delayWriteIdx] = fxIn + delayOut * dlyFb
            delayWriteIdx += 1
            if delayWriteIdx >= delayBufferSize { delayWriteIdx = 0 }

            // Combine: dry + wet sends (dry always at unity).
            let voiceOut = fxIn + revWet * revMix + delayOut * dlyMix

            // Equal-power pan: panT in [0, 0.5], gains cos(π·t), sin(π·t).
            let panT = (Double(p) + 1.0) * 0.25
            let lGain = Float(__cospi(panT))
            let rGain = Float(__sinpi(panT))

            left[i] += voiceOut * lGain
            right[i] += voiceOut * rGain
        }

        phase = ph
        currentFreq = f
        currentAmp = a
        currentPan = p
    }

    /// Recompute biquad coefficients from current type / cutoff / Q.
    /// RBJ Audio EQ Cookbook formulas. Called once per render buffer.
    @inline(__always)
    private func updateBiquadCoefficients(cutoff: Double) {
        let nyquist = sampleRate * 0.45
        let f = max(20.0, min(nyquist, cutoff))
        let omega = 2.0 * .pi * f / sampleRate
        let cosw = cos(omega)
        let sinw = sin(omega)
        let q = max(0.3, filterQ)
        let alpha = sinw / (2.0 * q)
        let a0 = 1.0 + alpha
        let a1 = -2.0 * cosw
        let a2 = 1.0 - alpha
        var b0: Double = 0, b1: Double = 0, b2: Double = 0
        switch filterType {
        case .lowpass:
            b0 = (1.0 - cosw) * 0.5
            b1 = 1.0 - cosw
            b2 = (1.0 - cosw) * 0.5
        case .highpass:
            b0 = (1.0 + cosw) * 0.5
            b1 = -(1.0 + cosw)
            b2 = (1.0 + cosw) * 0.5
        case .bandpass:
            b0 = alpha
            b1 = 0
            b2 = -alpha
        }
        bqB0 = b0 / a0
        bqB1 = b1 / a0
        bqB2 = b2 / a0
        bqA1 = a1 / a0
        bqA2 = a2 / a0
    }
}
