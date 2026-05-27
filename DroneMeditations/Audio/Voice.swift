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

    // 4 LFOs with user-editable shape + target. Mirror of LfoState.
    var lfoShapes: [LfoState.Shape]   = [.sine, .sampleAndHold, .sine, .sine]
    /// v1.1 multi-target: each LFO drives a SET of destinations
    /// simultaneously. v1.0 was single-target (one LfoState.Target per
    /// LFO); now an LFO can route to e.g. {pan, pitch, cutoff} all
    /// at once. The render loop iterates each set.
    var lfoTargets: [Set<LfoState.Target>] = [[.pan], [.amplitude], [.cutoff], [.pitch]]
    var lfoRatesHz: [Double]          = [0.25, 0.50, 0.30, 0.30]
    var lfoDepths: [Double]           = [0.0, 0.0, 0.0, 0.0]
    private var lfoPhases: [Double]   = [0.0, 0.0, 0.0, 0.0]
    private var lfoHolds: [Double]    = [0.0, 0.0, 0.0, 0.0]

    // Biquad filter (LP / HP / BP). UI-writable targets + coefficients computed per render.
    var filterType: FilterState.FilterType = .lowpass
    var filterCutoffHz: Double = 4000.0
    var filterQ: Double = 0.7

    // Per-voice soft-saturation drive applied to the raw oscillator/sample/
    // noise output before the filter. drive = 1.0 → linear (no change).
    // drive > 1 → progressively warmer / more harmonic content through a
    // tanh waveshaper, output normalized so peaks stay within ~[-1, 1].
    // Useful for Sunn O))) amp fuzz, Earth doom grit, NWW texture, gentle
    // tape saturation for Basinski.
    var drive: Double = 1.0

    // Per-voice timing envelope. Voice is silent for `startDelaySec` after
    // transport play, then fades in over 8 s. If `playDurationSec` > 0,
    // voice fades out over 8 s once it has been audible that long. Both
    // 0 = play immediately + forever (legacy behavior).
    //
    // `transportElapsed` is pushed in by the AudioEngine on each render
    // before this voice's render is called; the buffer-level envelope
    // value is computed at the START of render and applied multiplicatively
    // to the output. We don't interpolate per-sample because buffer sizes
    // are small (~5-10 ms) compared to the 8 s fade — sample-level
    // granularity isn't audible there.
    var startDelaySec: Double = 0
    var playDurationSec: Double = 0
    var transportElapsed: Double = .nan
    /// Slewed-from value of the timing-envelope multiplier; per-sample
    /// interpolation from this to the per-buffer target avoids clicks
    /// when the user taps a Now/Forever chip mid-session.
    private var currentTimingEnv: Double = 1.0

    // Pink-noise filter state — Paul Kellet's economy variant of the
    // Voss-McCartney algorithm. Six leaky integrators of white noise plus
    // a high-frequency compensation tap give a flat 1/f spectrum.
    private var pinkB0: Double = 0
    private var pinkB1: Double = 0
    private var pinkB2: Double = 0
    private var pinkB3: Double = 0
    private var pinkB4: Double = 0
    private var pinkB5: Double = 0
    private var pinkB6: Double = 0

    // Granular mode — UI-writable targets. Only consumed when waveform ==
    // .granular. The scheduler fires Hann-windowed pink-noise grains at the
    // requested density; `grainJitter` randomizes inter-grain timing; each
    // grain gets a random pan offset scaled by `grainPanSpread`. See
    // GrainState for value ranges + meanings.
    var grainSizeMs: Double      = 80
    var grainDensityHz: Double   = 8
    var grainJitter: Double      = 0.6
    var grainPanSpread: Double   = 0.5
    // Scheduler state — samples until the next grain fires; the currently
    // active grain's length + position; per-grain pan offset added to the
    // smoothed `p` only for the equal-power pan calc (slew untouched).
    private var grainSamplesUntilNext: Int = 0
    private var grainCurrentLength: Int    = 0
    private var grainCurrentPos: Int       = 0
    private var grainCurrentPanOffset: Float = 0

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
    // Sample play-window — fractions of the loaded sample length (0..1).
    // Playback loops between sampleStartFrac and sampleEndFrac. Defaults
    // to (0, 1) = play whole sample. `sampleFadeInSec` / `sampleFadeOutSec`
    // apply a crossfade gain at the loop boundary for seamless ambient
    // loops. All four are UI-writable via AudioEngine setters.
    var sampleStartFrac: Double = 0.0
    var sampleEndFrac: Double = 1.0
    var sampleFadeInSec: Double = 0.0
    var sampleFadeOutSec: Double = 0.0

    // Reverb (Schroeder JCRev: 4 parallel combs + 2 series allpasses).
    var reverbDecaySec: Double = 2.0
    var reverbMix: Float = 0.0

    /// Quantize-to-scale state (v1.1). When `pitchQuantizeToScale` is
    /// true, the voice render snaps its effective frequency to the
    /// nearest entry in `scaleNotesHz`. The cache is populated from
    /// DroneViewModel.updateScaleNotes(for:) whenever chord / tuning /
    /// voice base freq changes, spanning 2 octaves up from the voice's
    /// base frequency.
    var pitchQuantizeToScale: Bool = false
    var scaleNotesHz: [Double] = []
    private static let combLengths: [Int] = [1116, 1188, 1277, 1356]
    private static let allpassLengths: [Int] = [556, 441]
    private static let allpassFb: Double = 0.5
    private var combBuffers: [[Float]] = []
    private var combWriteIdx: [Int] = [0, 0, 0, 0]
    private var combFb: [Double]      = [0, 0, 0, 0]
    private var allpassBuffers: [[Float]] = []
    private var allpassWriteIdx: [Int] = [0, 0]

    // Delay — two circular buffers (L, R) so we can support stereo +
    // ping-pong properly. Mono mode just uses the L buffer; R sits silent.
    enum DelayMode: Int { case mono = 0, stereo = 1, pingPong = 2 }
    var delayTimeSec: Double = 0.30
    var delayFeedback: Float = 0.40
    var delayMix: Float = 0.0
    var delayMode: DelayMode = .mono
    private var delayBufferL: [Float] = []
    private var delayBufferR: [Float] = []
    private var delayBufferSize: Int = 0
    private var delayWriteIdxL: Int = 0
    private var delayWriteIdxR: Int = 0

    // Stereo chorus — two short delay lines modulated by a sine LFO whose
    // L/R phases are offset by `chorusWidth × π` so the L and R wet signals
    // breathe in counter-phase, giving width without flanging.
    var chorusRateHz: Double = 0.5
    var chorusDepth: Double  = 0.4
    var chorusWidth: Double  = 0.7
    var chorusMix: Float     = 0.0
    private var chorusBufferL: [Float] = []
    private var chorusBufferR: [Float] = []
    private var chorusBufferSize: Int  = 0
    private var chorusWriteIdx: Int    = 0
    private var chorusLfoPhaseL: Double = 0
    private var chorusLfoPhaseR: Double = 0
    /// Last value of chorusWidth seen during render; used to re-seed R LFO
    /// phase when the user changes width (otherwise width changes silently
    /// take effect only on the next play start).
    private var lastChorusWidth: Double = 0.7

    // ── Cross-oscillator FM ───────────────────────────────────────────
    // The carrier pulls samples from the modulator's raw oscillator output
    // buffer (provided by AudioEngine each render call). 1-buffer latency
    // is acceptable for FM at typical iOS buffer sizes (~5-10 ms).
    var fmIndex: Double = 0          // modulation index in Hz (peak excursion)
    /// -1 = no FM; otherwise the index (0..3) of the modulator voice. The
    /// AudioEngine reads this each render to set fmInputBuffer below.
    var fmSourceIndex: Int = -1
    var fmInputBuffer: UnsafePointer<Float>? = nil
    var fmInputCount: Int = 0
    /// After render, holds the voice's raw oscillator output (post-FM,
    /// pre-filter). AudioEngine snapshots this into its own storage for
    /// the next render's FM source lookups.
    private(set) var lastRawBuffer: [Float] = Array(repeating: 0, count: 4096)
    private(set) var lastRawCount: Int = 0

    // Render-thread state
    private var phase: Double = 0.0
    private var currentFreq: Double = 220.0
    private var currentAmp: Float = 0.0
    private var currentPan: Float = 0.0

    /// The currently playing (slewed + LFO-modulated) frequency, in Hz.
    /// Visualizations read this to morph in real time as pitch LFOs play.
    /// Updated on the audio render thread; safe-enough to read from the UI
    /// thread since aligned Double writes are tear-free on Apple Silicon.
    var liveFrequencyHz: Double { currentFreq }

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
        // (Note: delayBuffer is now two separate L/R circular buffers; see init below.)
        self.combBuffers = Voice.combLengths.map { Array(repeating: 0, count: $0) }
        self.allpassBuffers = Voice.allpassLengths.map { Array(repeating: 0, count: $0) }
        self.delayBufferSize = Int(sampleRate * 2.0)
        self.delayBufferL = Array(repeating: 0, count: delayBufferSize)
        self.delayBufferR = Array(repeating: 0, count: delayBufferSize)
        // Chorus circular buffer: 50 ms is plenty for the 8±12 ms swing range.
        self.chorusBufferSize = max(32, Int(sampleRate * 0.05))
        self.chorusBufferL = Array(repeating: 0, count: chorusBufferSize)
        self.chorusBufferR = Array(repeating: 0, count: chorusBufferSize)
        // Seed R-channel LFO phase by the width offset so L/R move counter-phase.
        self.chorusLfoPhaseR = chorusWidth * 0.5
        self.lastChorusWidth = chorusWidth
    }

    /// Render `frameCount` stereo samples, summing into `left` and `right` (output is additive).
    @inline(__always)
    func render(frameCount: Int, left: UnsafeMutablePointer<Float>, right: UnsafeMutablePointer<Float>) {
        // If solo/mute disables this voice, ramp amp toward 0 instead of cutting hard.
        let baseAmp: Float = effectiveEnabled && !isMuted ? targetAmplitude : 0
        let basePan: Float = targetPan
        let wave = waveform

        // ── Advance LFOs once per buffer and dispatch by target.
        let bufferSeconds = Double(frameCount) / sampleRate
        var panMod: Double = 0
        var ampScale: Double = 1.0
        var cutoffOct: Double = 0
        var pitchSemitones: Double = 0
        // Modulation accumulators for the new (v1.1) targets.
        // qOct is added to log2(filterQ); fmIndexMod is added directly
        // to fmIndex (Hz). Both clamped at their application sites.
        var qOct: Double = 0
        var fmIndexMod: Double = 0
        for k in 0..<4 {
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
            case .triangle:
                // Linear ↗↘ — smoother than square, sharper than sine.
                let p = lfoPhases[k]
                value = p < 0.5 ? (4.0 * p - 1.0) : (3.0 - 4.0 * p)
            case .square:
                value = lfoPhases[k] < 0.5 ? 1.0 : -1.0
            case .sampleAndHold:
                if stepped || lfoHolds[k] == 0 {
                    lfoHolds[k] = Double.random(in: -1.0 ... 1.0)
                }
                value = lfoHolds[k]
            case .sawtooth:
                // Rising sawtooth: -1 → +1 linearly over the phase,
                // then jumps back. Classic LFO ramp-up for filter
                // sweeps, pitch rises, etc.
                value = 2.0 * lfoPhases[k] - 1.0
            case .ramp:
                // Falling ramp (sometimes called "inverse sawtooth"):
                // +1 → -1 linearly over the phase, then jumps back.
                // Useful for envelope-like attack-then-decay sweeps
                // when paired with the right target.
                value = 1.0 - 2.0 * lfoPhases[k]
            }
            // v1.1: iterate each LFO's target SET so a single LFO can
            // drive multiple destinations simultaneously (pan + pitch
            // + cutoff together, etc.).
            for target in lfoTargets[k] {
                switch target {
                case .pan:       panMod         += depth * value
                case .amplitude: ampScale       *= (1.0 + 0.6 * depth * value)
                case .cutoff:    cutoffOct      += 2.0 * depth * value
                case .pitch:
                    // Pitch swing widens when quantize-to-scale is on
                    // so the LFO can actually reach distant chord
                    // notes — otherwise ±2 semis only ever snaps to
                    // the 1-2 closest scale degrees and the modulation
                    // is inaudible. Quantize on: ±12 semis (1 octave)
                    // at full depth → arpeggio across the chord with
                    // S&H. Quantize off: ±2 semis = classic vibrato.
                    let pitchSpan: Double = pitchQuantizeToScale ? 12.0 : 2.0
                    pitchSemitones += pitchSpan * depth * value
                case .filterQ:
                    // ±1.5 octaves of Q at full depth — multiplicative
                    // in log-Q space. Subtle "resonance pumping" at
                    // low depth, very pronounced sweeps at high depth.
                    qOct += 1.5 * depth * value
                case .fmIndex:
                    // ±200 Hz FM index swing at full depth. Additive.
                    // Clamped later when applied to the FM source.
                    fmIndexMod += 200.0 * depth * value
                }
            }
        }

        let panTarget = Float(max(-1.0, min(1.0, Double(basePan) + panMod)))
        let ampTarget = Float(max(0.0, min(1.0, Double(baseAmp) * ampScale)))
        // Pitch-modulated frequency target — slew loop tracks this rather than
        // the raw targetFrequencyHz when an LFO is routed to pitch.
        var effectiveFreqTarget = targetFrequencyHz * pow(2.0, pitchSemitones / 12.0)
        // v1.1 quantize-to-scale: snap the post-modulation pitch to the
        // nearest chord note (cache populated by DroneViewModel when
        // chord/tuning/base-freq changes). Snap is in log space so the
        // "nearest" measure is musically meaningful (a halfstep above
        // and below count as equidistant). No-op when the cache is
        // empty or the flag is off.
        if pitchQuantizeToScale, !scaleNotesHz.isEmpty, effectiveFreqTarget > 0 {
            let logTarget = log2(effectiveFreqTarget)
            var bestNote = scaleNotesHz[0]
            var bestDiff = abs(log2(bestNote) - logTarget)
            for n in scaleNotesHz where n > 0 {
                let d = abs(log2(n) - logTarget)
                if d < bestDiff { bestDiff = d; bestNote = n }
            }
            effectiveFreqTarget = bestNote
        }

        // ── Update biquad coefficients with LFO-modulated cutoff + Q.
        let effectiveCutoff = filterCutoffHz * pow(2.0, cutoffOct)
        let effectiveQ = max(FilterState.qMin,
                             min(FilterState.qMax, filterQ * pow(2.0, qOct)))
        updateBiquadCoefficients(cutoff: effectiveCutoff, q: effectiveQ)

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

        // Per-voice timing envelope target for this buffer. Smoothed per-
        // sample below by interpolating from currentTimingEnv → envTarget
        // across the buffer so toggles don't click. Math: silent before
        // startDelay; 8-second fade-in; full; optional 8-second fade-out
        // after playDuration; then silent. transportElapsed = NaN means
        // transport stopped — leave the multiplier alone (master fadeOut
        // handles real silence).
        let envTarget: Double
        if !transportElapsed.isFinite {
            envTarget = currentTimingEnv
        } else if startDelaySec <= 0 && playDurationSec <= 0 {
            envTarget = 1.0
        } else {
            let fade = 8.0
            if transportElapsed < startDelaySec {
                envTarget = 0
            } else if transportElapsed < startDelaySec + fade {
                envTarget = (transportElapsed - startDelaySec) / fade
            } else if playDurationSec > 0 && transportElapsed >= startDelaySec + playDurationSec {
                let foe = transportElapsed - (startDelaySec + playDurationSec)
                envTarget = foe >= fade ? 0 : 1 - (foe / fade)
            } else {
                envTarget = 1
            }
        }
        let envStep: Double = frameCount > 0 ? (envTarget - currentTimingEnv) / Double(frameCount) : 0

        // Width changes can't apply mid-render without clicks; we snap the
        // R-channel phase to the requested offset whenever width changes
        // appreciably (>5% delta) at buffer boundaries.
        if abs(chorusWidth - lastChorusWidth) > 0.05 {
            chorusLfoPhaseR = chorusLfoPhaseL + chorusWidth * 0.5
            chorusLfoPhaseR -= floor(chorusLfoPhaseR)
            lastChorusWidth = chorusWidth
        }
        let chMix = chorusMix
        let chSwing = chorusDepth * ChorusState.maxSwing
        let chBaseSec = ChorusState.baseSec
        let chRatePerSample = chorusRateHz

        // FM source (1-buffer-latency raw signal from modulator voice).
        // fmIndex + fmIndexMod (LFO-driven) clamped to [0, 800] Hz to
        // match the slider's nominal range.
        let fmIdx = max(0.0, min(800.0, fmIndex + fmIndexMod))
        let fmSrcPtr = fmInputBuffer
        let fmSrcCount = fmInputCount

        // Resize lastRawBuffer if frame size grew.
        if lastRawBuffer.count < frameCount {
            lastRawBuffer = Array(repeating: 0, count: frameCount)
        }

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
        // Uses the effective (pitch-LFO-modulated) freq so vibrato applies to samples too.
        let isSampleMode = (wave == .sample) && (sampleData?.isEmpty == false)
        let sampleIncrement: Double = isSampleMode
            ? max(0.05, min(20.0, effectiveFreqTarget / 220.0)) * (sampleNativeRate / sampleRate)
            : 0
        // Snapshot the array's storage pointer outside the loop to avoid per-sample ARC.
        let sampleCount = sampleData?.count ?? 0
        // Precompute play-window in frames + fade lengths in samples once
        // per render block — these are user-set and stable across one
        // buffer. Clamp endFrac > startFrac and bound to [1, sampleCount].
        let startClamped = max(0.0, min(0.999, sampleStartFrac))
        let endClamped = max(startClamped + 0.001, min(1.0, sampleEndFrac))
        let windowStartFrame = Double(sampleCount) * startClamped
        let windowEndFrame = Double(sampleCount) * endClamped
        // (windowLength = windowEndFrame - windowStartFrame is conceptually
        // useful but never materialized here — the overshoot-clamp on line
        // ~414 below uses `samplePosition >= windowEndFrame` instead,
        // which is the same check expressed in absolute coordinates.)
        // Fade lengths in sample frames at the sample's native rate.
        let fadeInFrames = max(0.0, sampleFadeInSec * sampleNativeRate)
        let fadeOutFrames = max(0.0, sampleFadeOutSec * sampleNativeRate)

        for i in 0..<frameCount {
            f += (effectiveFreqTarget - f) * fStep
            a += Float((Double(ampTarget) - Double(a)) * aStep)
            p += Float((Double(panTarget) - Double(p)) * pStep)

            var raw: Double
            if isSampleMode, sampleCount > 0 {
                // Bring samplePosition into [windowStart, windowEnd) on
                // first frame and on every wrap. Per-sample loop logic
                // wraps cheaply when we reach windowEnd.
                if samplePosition < windowStartFrame || samplePosition >= windowEndFrame {
                    samplePosition = windowStartFrame
                }
                let pos = samplePosition
                let i0 = Int(pos) % sampleCount
                let i1 = (i0 + 1) % sampleCount
                let frac = pos - floor(pos)
                let s0 = Double(sampleData![i0])
                let s1 = Double(sampleData![i1])
                raw = s0 * (1.0 - frac) + s1 * frac

                // Crossfade gain at loop boundaries — linear ramps.
                // Distance from windowStart / to windowEnd governs the
                // fade-in / fade-out gain respectively.
                if fadeInFrames > 0 || fadeOutFrames > 0 {
                    let posInWindow = pos - windowStartFrame
                    var fadeMul: Double = 1.0
                    if fadeInFrames > 0 && posInWindow < fadeInFrames {
                        fadeMul *= posInWindow / fadeInFrames
                    }
                    let posFromEnd = windowEndFrame - pos
                    if fadeOutFrames > 0 && posFromEnd < fadeOutFrames {
                        fadeMul *= posFromEnd / fadeOutFrames
                    }
                    raw *= fadeMul
                }

                samplePosition += sampleIncrement
                if samplePosition >= windowEndFrame {
                    // Wrap back to start of the play window (NOT 0).
                    let overshoot = samplePosition - windowEndFrame
                    samplePosition = windowStartFrame + overshoot
                    // If overshoot > windowLength (e.g. very high pitch
                    // shift), just snap to start.
                    if samplePosition >= windowEndFrame {
                        samplePosition = windowStartFrame
                    }
                }
            } else if wave.isNoise {
                // Noise voices skip phase math + FM entirely (no periodic
                // frequency to modulate). Frequency knob has no effect.
                if wave == .whiteNoise {
                    raw = Double.random(in: -1.0 ... 1.0)
                } else {
                    // Pink noise (Paul Kellet). Six leaky integrators + a HF
                    // compensation tap on the raw white sample. Output gain
                    // 0.11 keeps peaks roughly in [-1, 1]. Reused as the
                    // source for granular mode below.
                    let white = Double.random(in: -1.0 ... 1.0)
                    pinkB0 = 0.99886 * pinkB0 + white * 0.0555179
                    pinkB1 = 0.99332 * pinkB1 + white * 0.0750759
                    pinkB2 = 0.96900 * pinkB2 + white * 0.1538520
                    pinkB3 = 0.86650 * pinkB3 + white * 0.3104856
                    pinkB4 = 0.55000 * pinkB4 + white * 0.5329522
                    pinkB5 = -0.7616 * pinkB5 - white * 0.0168980
                    raw = (pinkB0 + pinkB1 + pinkB2 + pinkB3 + pinkB4
                           + pinkB5 + pinkB6 + white * 0.5362) * 0.11
                    pinkB6 = white * 0.115926

                    // Granular: window the running pink-noise sample with a
                    // Hann envelope, gated by a Poisson-ish scheduler. When
                    // no grain is active, output silence — the negative-space
                    // is what makes geiger / rain textures feel sparse and
                    // organic. Boost active samples by 3× to compensate for
                    // the duty cycle so perceived loudness stays in the same
                    // ballpark as continuous pink noise.
                    if wave == .granular {
                        if grainSamplesUntilNext <= 0 {
                            // Start a new grain.
                            let lenSamples = max(8, Int(grainSizeMs * 0.001 * sampleRate))
                            grainCurrentLength = lenSamples
                            grainCurrentPos = 0
                            grainCurrentPanOffset = Float(Double.random(in: -1.0 ... 1.0) * grainPanSpread)
                            // Mean inter-grain spacing from density. jitter
                            // randomizes the gap multiplicatively — at
                            // jitter=1 the gap varies 0.3×..2.5× the mean,
                            // producing markedly irregular grain trains.
                            let meanGap = sampleRate / max(0.5, grainDensityHz)
                            let lo = max(0.05, 1.0 - grainJitter * 0.7)
                            let hi = 1.0 + grainJitter * 1.5
                            let gap = meanGap * Double.random(in: lo...hi)
                            // Don't schedule next grain to start before the
                            // current one finishes (avoid overlap pile-up at
                            // sparse density + long grains).
                            grainSamplesUntilNext = max(lenSamples + 8, Int(gap))
                        }
                        if grainCurrentPos < grainCurrentLength {
                            let t = Double(grainCurrentPos) / Double(grainCurrentLength)
                            let window = 0.5 * (1.0 - cos(2.0 * .pi * t))
                            raw *= window * 3.0
                            grainCurrentPos += 1
                        } else {
                            raw = 0
                        }
                        grainSamplesUntilNext -= 1
                    }
                }
            } else {
                // Synth oscillator: advance phase + sample the waveform formula.
                // FM: add modulator * fmIndex (Hz) to the per-sample phase
                // increment. Uses raw modulator output → instantaneous freq
                // excursion of ±|fmIndex|·|modulator| Hz.
                var freqInst = f
                if fmIdx > 0.001, let src = fmSrcPtr, i < fmSrcCount {
                    freqInst += Double(src[i]) * fmIdx
                }
                ph += freqInst * invSR
                if ph >= 1.0 { ph -= floor(ph) }
                if ph < 0    { ph += ceil(-ph) }   // negative FM excursions
                raw = wave.sample(phase: ph)
            }
            // Per-voice drive (soft-saturation). 1.0 = bypass — no math.
            // tanh waveshaper, normalized so output peak ≈ 1.0 regardless
            // of drive amount, producing warm harmonic content without
            // brutally clipping.
            if drive > 1.001 {
                raw = tanh(raw * drive) / tanh(drive)
            }
            // Capture pre-filter raw for other voices' FM lookups next render.
            lastRawBuffer[i] = Float(raw)

            // Biquad Direct Form II Transposed.
            let y = bqB0 * raw + bqS1
            bqS1 = bqB1 * raw - bqA1 * y + bqS2
            bqS2 = bqB2 * raw - bqA2 * y
            let fxIn = Float(y) * a

            // ── Stereo Chorus ──
            // Two delay lines fed identically by `fxIn`, each read at a
            // sinusoidally-modulated tap length around the 8 ms base. The L
            // and R LFOs run at the same rate but with a width-set phase
            // offset, producing counter-phase L/R wet signals.
            let chOutL: Float
            let chOutR: Float
            if chMix > 0.0001 {
                chorusLfoPhaseL += chRatePerSample * invSR
                if chorusLfoPhaseL >= 1.0 { chorusLfoPhaseL -= floor(chorusLfoPhaseL) }
                chorusLfoPhaseR += chRatePerSample * invSR
                if chorusLfoPhaseR >= 1.0 { chorusLfoPhaseR -= floor(chorusLfoPhaseR) }
                let lfoL = sin(chorusLfoPhaseL * 2.0 * .pi)
                let lfoR = sin(chorusLfoPhaseR * 2.0 * .pi)
                let tapSecL = chBaseSec + lfoL * chSwing
                let tapSecR = chBaseSec + lfoR * chSwing
                let chWetL = chorusReadFractional(buffer: chorusBufferL,
                                                  size: chorusBufferSize,
                                                  writeIdx: chorusWriteIdx,
                                                  tapSec: tapSecL)
                let chWetR = chorusReadFractional(buffer: chorusBufferR,
                                                  size: chorusBufferSize,
                                                  writeIdx: chorusWriteIdx,
                                                  tapSec: tapSecR)
                chorusBufferL[chorusWriteIdx] = fxIn
                chorusBufferR[chorusWriteIdx] = fxIn
                chorusWriteIdx += 1
                if chorusWriteIdx >= chorusBufferSize { chorusWriteIdx = 0 }
                chOutL = fxIn * (1.0 - chMix) + chWetL * chMix
                chOutR = fxIn * (1.0 - chMix) + chWetR * chMix
            } else {
                // Bypass: still write into the buffer so taking the slider up
                // mid-play doesn't expose zeros, but skip the LFO math + read.
                chorusBufferL[chorusWriteIdx] = fxIn
                chorusBufferR[chorusWriteIdx] = fxIn
                chorusWriteIdx += 1
                if chorusWriteIdx >= chorusBufferSize { chorusWriteIdx = 0 }
                chOutL = fxIn
                chOutR = fxIn
            }
            // Mono sum drives reverb + delay (those stages stay mono-in).
            let chMono = (chOutL + chOutR) * 0.5
            let fxInMono = chMono

            // ── Reverb (Schroeder JCRev): 4 parallel combs + 2 series allpasses.
            var combSum: Double = 0
            for k in 0..<4 {
                let bufLen = Voice.combLengths[k]
                var wIdx = combWriteIdx[k]
                let combOut = combBuffers[k][wIdx]
                combSum += Double(combOut)
                combBuffers[k][wIdx] = Float(Double(fxInMono) + Double(combOut) * combFb[k])
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

            // ── Delay (two circular buffers, mode-dependent feedback).
            // Read current L + R taps before writing new samples.
            var rIdxL = delayWriteIdxL - delayTapSamples
            if rIdxL < 0 { rIdxL += delayBufferSize }
            var rIdxR = delayWriteIdxR - delayTapSamples
            if rIdxR < 0 { rIdxR += delayBufferSize }
            let delayOutL = delayBufferL[rIdxL]
            let delayOutR = delayBufferR[rIdxR]

            // Write next samples per mode:
            //   mono     — single tap; only L buffer fed (R sits at 0).
            //   stereo   — both buffers fed identically with self-feedback.
            //   pingPong — L gets dry + R's bounce; R gets L's bounce only.
            switch delayMode {
            case .mono:
                delayBufferL[delayWriteIdxL] = fxInMono + delayOutL * dlyFb
                delayBufferR[delayWriteIdxR] = 0
            case .stereo:
                delayBufferL[delayWriteIdxL] = fxInMono + delayOutL * dlyFb
                delayBufferR[delayWriteIdxR] = fxInMono + delayOutR * dlyFb
            case .pingPong:
                delayBufferL[delayWriteIdxL] = fxInMono + delayOutR * dlyFb
                delayBufferR[delayWriteIdxR] = delayOutL * dlyFb
            }
            delayWriteIdxL += 1
            if delayWriteIdxL >= delayBufferSize { delayWriteIdxL = 0 }
            delayWriteIdxR += 1
            if delayWriteIdxR >= delayBufferSize { delayWriteIdxR = 0 }

            // Compose: dry + reverb get the equal-power pan. Delay output
            // for stereo/pingPong goes directly to L/R unpanned, preserving
            // the cross-feedback's left/right separation. Mono delay
            // follows the dry pan. Chorus's "side" portion (deviation from
            // mono) passes through unpanned so the stereo width persists
            // regardless of pan position.
            let dryReverbOut = fxInMono + revWet * revMix
            // Granular per-grain pan offset is added on top of the smoothed
            // pan target so each grain lands in a random stereo location
            // without disturbing the voice's base pan slew.
            let pPlusGrain = (wave == .granular)
                ? max(-1.0, min(1.0, Double(p) + Double(grainCurrentPanOffset)))
                : Double(p)
            let panT = (pPlusGrain + 1.0) * 0.25
            let lGain = Float(__cospi(panT))
            let rGain = Float(__sinpi(panT))

            let dryL = dryReverbOut * lGain
            let dryR = dryReverbOut * rGain
            // Chorus side signal (already part of fxInMono via the mid; we
            // add the deviation here so L and R each carry their LFO-tapped
            // tail independently of pan).
            let sideL = chOutL - chMono
            let sideR = chOutR - chMono
            let dlyL: Float
            let dlyR: Float
            switch delayMode {
            case .mono:
                let m = delayOutL * dlyMix
                dlyL = m * lGain
                dlyR = m * rGain
            case .stereo, .pingPong:
                dlyL = delayOutL * dlyMix
                dlyR = delayOutR * dlyMix
            }

            // Slew the per-buffer timing-envelope target across the buffer
            // so chip toggles don't click. After the loop, currentTimingEnv
            // == envTarget within rounding.
            currentTimingEnv += envStep
            let envMul = Float(currentTimingEnv)
            left[i]  += (dryL + sideL + dlyL) * envMul
            right[i] += (dryR + sideR + dlyR) * envMul
        }
        lastRawCount = frameCount

        phase = ph
        currentFreq = f
        currentAmp = a
        currentPan = p
    }

    // Linear-interpolated read from a circular chorus buffer.
    @inline(__always)
    private func chorusReadFractional(buffer: [Float], size: Int, writeIdx: Int, tapSec: Double) -> Float {
        let tapSamples = max(1.0, min(Double(size - 2), tapSec * sampleRate))
        let pos = Double(writeIdx) - tapSamples
        var basePos = pos
        while basePos < 0 { basePos += Double(size) }
        let i0 = Int(basePos) % size
        let i1 = (i0 + 1) % size
        let frac = Float(basePos - floor(basePos))
        return buffer[i0] * (1.0 - frac) + buffer[i1] * frac
    }

    /// Recompute biquad coefficients from current type / cutoff / Q.
    /// RBJ Audio EQ Cookbook formulas. Called once per render buffer.
    /// The caller passes in the EFFECTIVE Q (post-LFO-modulation) so
    /// the .filterQ LFO target actually changes resonance per buffer.
    @inline(__always)
    private func updateBiquadCoefficients(cutoff: Double, q: Double) {
        let nyquist = sampleRate * 0.45
        let f = max(20.0, min(nyquist, cutoff))
        let omega = 2.0 * .pi * f / sampleRate
        let cosw = cos(omega)
        let sinw = sin(omega)
        let q = max(0.3, q)
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
