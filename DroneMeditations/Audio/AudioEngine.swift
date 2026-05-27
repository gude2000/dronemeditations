import Foundation
import AVFoundation

/// Owns AVAudioEngine and four `Voice` oscillators. UI code updates voice targets;
/// the engine's source node renders sample-accurate sine/triangle/saw/square audio
/// with smoothed parameter ramps.
final class AudioEngine {
    let engine = AVAudioEngine()
    let voices: [Voice]
    let sampleRate: Double

    /// Master output level (0..1). Setting cancels any in-progress fade and
    /// snaps to the new value; also remembers it as the target for the next
    /// fade-in (so play after volume change resumes to the right level).
    var masterVolume: Float {
        get { engine.mainMixerNode.outputVolume }
        set {
            let clamped = max(0, min(1, newValue))
            masterTarget = clamped
            cancelFade()
            engine.mainMixerNode.outputVolume = clamped
        }
    }
    private var masterTarget: Float = 0.30
    private var fadeTimer: Timer?

    /// Transport elapsed seconds, pushed in by DroneController on every
    /// transport tick. The audio render thread reads it once per render
    /// block and fans it out to each voice so per-voice timing envelopes
    /// (startDelaySec + playDurationSec) can shape volume. NaN = stopped.
    var transportElapsed: Double = .nan

    private var sourceNode: AVAudioSourceNode!
    private var isSessionConfigured = false

    init() {
        // Use the system's preferred sample rate; the source node format must match.
        let session = AVAudioSession.sharedInstance()
        let sr = session.sampleRate > 0 ? session.sampleRate : 48000.0
        self.sampleRate = sr
        self.voices = (0..<4).map { Voice(id: $0, sampleRate: sr) }
        attachSourceNode()
        // Default 0.30 — with 4 voices + reverb/delay wet sends, anything higher
        // can hit the soft-limiter and audibly compress. Remember as the fade
        // target; actual outputVolume starts at 0 and is ramped by play().
        masterTarget = 0.30
        engine.mainMixerNode.outputVolume = 0
    }

    private func attachSourceNode() {
        guard let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 2) else {
            fatalError("Could not create stereo audio format at \(sampleRate) Hz")
        }
        // Capture the voices array directly so the render closure never touches self.
        let voices = self.voices
        sourceNode = AVAudioSourceNode(format: format) { _, _, frameCount, abl -> OSStatus in
            let ablPtr = UnsafeMutableAudioBufferListPointer(abl)
            // Expect 2 non-interleaved float channels.
            guard ablPtr.count >= 2,
                  let leftRaw = ablPtr[0].mData,
                  let rightRaw = ablPtr[1].mData else {
                return noErr
            }
            let n = Int(frameCount)
            let left = leftRaw.assumingMemoryBound(to: Float.self)
            let right = rightRaw.assumingMemoryBound(to: Float.self)

            // Zero the output before voices sum in.
            for i in 0..<n { left[i] = 0; right[i] = 0 }

            // Resolve solo logic for this buffer.
            var anySoloed = false
            for v in voices where v.isSoloed {
                anySoloed = true
                break
            }
            // For each voice, wire its FM input pointer to the source voice's
            // PREVIOUS render's raw buffer (1-buffer latency — fine for FM at
            // typical iOS buffer sizes ~5-10 ms). Voices read from `src.lastRawBuffer`
            // which holds whatever was written last call; the new call updates
            // each voice's own lastRawBuffer in place.
            // Snapshot transport elapsed once for this render block so all
            // four voices see the same time for their envelope evaluation.
            let elapsed = self.transportElapsed
            for v in voices {
                v.effectiveEnabled = anySoloed ? v.isSoloed : true
                v.transportElapsed = elapsed
                let srcIdx = v.fmSourceIndex
                if srcIdx >= 0 && srcIdx < voices.count && srcIdx != v.id {
                    let src = voices[srcIdx]
                    src.lastRawBuffer.withUnsafeBufferPointer { srcPtr in
                        v.fmInputBuffer = srcPtr.baseAddress
                        v.fmInputCount = src.lastRawCount
                        v.render(frameCount: n, left: left, right: right)
                    }
                    v.fmInputBuffer = nil
                    v.fmInputCount = 0
                } else {
                    v.fmInputBuffer = nil
                    v.fmInputCount = 0
                    v.render(frameCount: n, left: left, right: right)
                }
            }
            // Soft-limit summed output at -0.1 dB ceiling (≈ 0.989) via tanh saturation.
            // Keeps peaks bounded without the brutality of hard clipping.
            let ceiling: Float = 0.989
            for i in 0..<n {
                left[i] = tanhf(left[i]) * ceiling
                right[i] = tanhf(right[i]) * ceiling
            }
            return noErr
        }
        engine.attach(sourceNode)
        engine.connect(sourceNode, to: engine.mainMixerNode, format: format)
    }

    // MARK: - Session lifecycle

    func configureSessionIfNeeded() throws {
        guard !isSessionConfigured else { return }
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
        try session.setActive(true, options: [])
        isSessionConfigured = true
    }

    func start() throws {
        try configureSessionIfNeeded()
        if !engine.isRunning {
            try engine.start()
        }
    }

    func stop() {
        if engine.isRunning {
            engine.stop()
        }
    }

    /// Disconnect + reconnect the source node → mainMixer connection so it
    /// renegotiates its format with whatever sample rate / channel layout
    /// the session is now offering. Called by `MicPitchDetector` after a
    /// session category swap, where AVAudioEngine has been observed to
    /// leave the source-node connection in a stale state — `isRunning`
    /// reports true but the render block is never called, so audio
    /// silently goes to zero. This forces a fresh negotiation that
    /// rewires the render path. Safe to call when the engine is stopped
    /// (intended call site), since `connect()` while stopped is the
    /// documented happy path for AVAudioEngine graph mutations.
    func refreshOutputGraph() {
        guard let src = sourceNode else { return }
        let format = engine.mainMixerNode.outputFormat(forBus: 0)
        engine.disconnectNodeOutput(src)
        engine.connect(src, to: engine.mainMixerNode, format: format)
    }

    // MARK: - Recording

    /// Output URL of the currently active recording, if any.
    private(set) var recordingURL: URL?
    private var recordingFile: AVAudioFile?

    /// Install a tap on the main mixer and write each render block to a CAF
    /// file in the Documents directory. Returns the URL of the file being
    /// captured, or nil if recording couldn't start.
    @discardableResult
    func startRecording() -> URL? {
        guard recordingFile == nil else { return recordingURL }
        let mixer = engine.mainMixerNode
        let format = mixer.outputFormat(forBus: 0)

        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd_HHmmss"
        let url = docs.appendingPathComponent("drone-meditations-\(df.string(from: Date())).caf")

        do {
            let file = try AVAudioFile(forWriting: url, settings: format.settings)
            recordingFile = file
            recordingURL = url
        } catch {
            return nil
        }

        // mainMixerNode bus 0 is shared with SpectrumTap. installTap throws
        // an NSException (uncatchable from Swift) if a tap is already
        // present, so pre-emptively remove any existing one. SpectrumTap
        // will need to be restarted by the user after recording stops.
        mixer.removeTap(onBus: 0)
        mixer.installTap(onBus: 0, bufferSize: 4096, format: format) { [weak self] buffer, _ in
            guard let file = self?.recordingFile else { return }
            do { try file.write(from: buffer) } catch { /* drop on error */ }
        }
        return url
    }

    /// Remove the tap and close the file. Returns the URL of the captured
    /// recording (caller can hand it to a share sheet).
    @discardableResult
    func stopRecording() -> URL? {
        guard recordingFile != nil else { return nil }
        engine.mainMixerNode.removeTap(onBus: 0)
        recordingFile = nil  // closes the file via AVAudioFile deinit
        let url = recordingURL
        recordingURL = nil
        return url
    }

    var isRecording: Bool { recordingFile != nil }

    /// Gently ramp master output up to `masterTarget` over `seconds`. Used by
    /// DroneController on play to avoid a hard cut-in.
    func fadeInMaster(seconds: Double = 3.0) {
        rampMaster(to: masterTarget, over: seconds, curve: .equalPower)
    }

    /// Ramp master output to silence over `seconds` with the chosen
    /// curve. Long fades (e.g. stop) should use `.smoothstep` for an
    /// even, gradual feel. Short fades (e.g. pause) can use
    /// `.exponential` for a snappier response. Awaits completion + a
    /// substantial post-silence buffer so a follow-up `engine.stop()`
    /// can't introduce a DC click.
    func fadeOutMaster(seconds: Double = 5.0, curve: FadeCurve = .smoothstep) async {
        rampMaster(to: 0, over: seconds, curve: curve)
        // Wait for the fade to fully complete.
        try? await Task.sleep(nanoseconds: UInt64((seconds + 0.10) * 1_000_000_000))
        // Snap to exact zero — floating-point dust at very low volumes
        // can still click on engine.stop().
        engine.mainMixerNode.outputVolume = 0
        // 200 ms of explicit silence at zero before any stop() runs.
        // Lets the hardware's downstream output buffer fully drain to
        // silence, so engine.stop() never interrupts non-zero samples.
        try? await Task.sleep(nanoseconds: 200_000_000)
    }

    /// Cancel any in-progress fade (without snapping volume).
    private func cancelFade() {
        fadeTimer?.invalidate()
        fadeTimer = nil
    }

    /// Curve shape for `rampMaster`.
    ///  - equalPower: sin-shaped, gentle onset — used for fade-ins.
    ///  - exponential: sharp early drop, gradual tail — "snappy" stop.
    ///  - smoothstep: slow start, faster middle, slow end (Hermite cubic).
    ///  - logarithmic: amplitude decays exponentially so the PERCEIVED
    ///    loudness (which is logarithmic in amplitude — every -6 dB
    ///    halves the perceived volume) drops at a steady rate. Sounds
    ///    "uniformly gradual" to the ear in a way smoothstep doesn't:
    ///    smoothstep is gradual in amplitude (linear-space) but the
    ///    last 20 % feels rushed because dropping from -10 dB to -∞
    ///    happens fast in amplitude terms. Logarithmic spreads the dB
    ///    drop evenly. The best curve for a "winding down" meditation
    ///    stop fade.
    enum FadeCurve { case linear, equalPower, exponential, smoothstep, logarithmic }

    private func rampMaster(to target: Float, over duration: Double, curve: FadeCurve = .linear) {
        cancelFade()
        guard duration > 0 else {
            engine.mainMixerNode.outputVolume = target
            return
        }
        let startVolume = engine.mainMixerNode.outputVolume
        let startDate = Date()
        // ~60 fps tick is buttery smooth for multi-second meditation fades
        // and well under any audible zipper-noise rate.
        let mixer = engine.mainMixerNode
        fadeTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60.0, repeats: true) { [weak self] timer in
            let elapsed = Date().timeIntervalSince(startDate)
            let tLin = min(1.0, elapsed / duration)
            let t: Double
            switch curve {
            case .linear:
                t = tLin
            case .equalPower:
                // sin curve — gentle onset, used for fade-in.
                t = sin(tLin * .pi / 2)
            case .exponential:
                // 1 - (1-t)^3 — sharp early drop, gradual tail. Feels
                // "snappy" for short fades, "abrupt at the start" for
                // long fades.
                t = 1 - pow(1 - tLin, 3)
            case .smoothstep:
                // Hermite cubic 3t² - 2t³ — slow at both endpoints,
                // faster in the middle. Feels uniformly gradual in
                // AMPLITUDE space but the last 20 % rushes in
                // perceived loudness terms (going from -10 dB to -∞
                // happens fast in amplitude).
                t = tLin * tLin * (3 - 2 * tLin)
            case .logarithmic:
                // amplitude = startVol * 10^(-2 * tLin), which makes
                // perceived loudness (= 20·log10(amp)) descend linearly
                // from 0 dB at tLin=0 to -40 dB at tLin=1. The final
                // snap to 0 (handled by the tLin >= 1 clamp below) is
                // inaudible at -40 dB. Used for the meditation stop
                // fade so the user hears a steady wind-down rather
                // than a hold-then-drop. Faster than smoothstep at the
                // same nominal duration because the perceived volume
                // descent begins immediately.
                t = 1 - pow(10, -2 * tLin)
            }
            mixer.outputVolume = startVolume + (target - startVolume) * Float(t)
            if tLin >= 1.0 {
                mixer.outputVolume = target
                timer.invalidate()
                self?.fadeTimer = nil
            }
        }
    }

    // MARK: - Convenience parameter setters (UI-thread safe)

    func setFrequency(_ hz: Double, for voiceIndex: Int) {
        guard voices.indices.contains(voiceIndex) else { return }
        voices[voiceIndex].targetFrequencyHz = max(1.0, hz)
    }

    func setAmplitude(_ amp: Double, for voiceIndex: Int) {
        guard voices.indices.contains(voiceIndex) else { return }
        voices[voiceIndex].targetAmplitude = Float(max(0, min(1, amp)))
    }

    func setPan(_ pan: Double, for voiceIndex: Int) {
        guard voices.indices.contains(voiceIndex) else { return }
        voices[voiceIndex].targetPan = Float(max(-1, min(1, pan)))
    }

    func setWaveform(_ wave: Waveform, for voiceIndex: Int) {
        guard voices.indices.contains(voiceIndex) else { return }
        voices[voiceIndex].waveform = wave
    }

    func setMute(_ muted: Bool, for voiceIndex: Int) {
        guard voices.indices.contains(voiceIndex) else { return }
        voices[voiceIndex].isMuted = muted
    }

    func setSolo(_ soloed: Bool, for voiceIndex: Int) {
        guard voices.indices.contains(voiceIndex) else { return }
        voices[voiceIndex].isSoloed = soloed
    }

    func setLfoRate(_ hz: Double, for voiceIndex: Int, lfoIndex: Int) {
        guard voices.indices.contains(voiceIndex),
              (0..<4).contains(lfoIndex) else { return }
        let clamped = max(LfoState.rateMin, min(LfoState.rateMax, hz))
        voices[voiceIndex].lfoRatesHz[lfoIndex] = clamped
    }

    func setLfoDepth(_ depth: Double, for voiceIndex: Int, lfoIndex: Int) {
        guard voices.indices.contains(voiceIndex),
              (0..<4).contains(lfoIndex) else { return }
        voices[voiceIndex].lfoDepths[lfoIndex] = max(0, min(1, depth))
    }

    func setLfoShape(_ shape: LfoState.Shape, for voiceIndex: Int, lfoIndex: Int) {
        guard voices.indices.contains(voiceIndex),
              (0..<4).contains(lfoIndex) else { return }
        voices[voiceIndex].lfoShapes[lfoIndex] = shape
    }

    func setLfoTarget(_ target: LfoState.Target, for voiceIndex: Int, lfoIndex: Int) {
        guard voices.indices.contains(voiceIndex),
              (0..<4).contains(lfoIndex) else { return }
        voices[voiceIndex].lfoTargets[lfoIndex] = target
    }

    func setFilterType(_ type: FilterState.FilterType, for voiceIndex: Int) {
        guard voices.indices.contains(voiceIndex) else { return }
        voices[voiceIndex].filterType = type
    }

    func setFilterCutoff(_ hz: Double, for voiceIndex: Int) {
        guard voices.indices.contains(voiceIndex) else { return }
        voices[voiceIndex].filterCutoffHz = max(FilterState.cutoffMin, min(FilterState.cutoffMax, hz))
    }

    func setFilterQ(_ q: Double, for voiceIndex: Int) {
        guard voices.indices.contains(voiceIndex) else { return }
        voices[voiceIndex].filterQ = max(FilterState.qMin, min(FilterState.qMax, q))
    }

    /// Voice timing envelope. 0 (default) for both means play immediately
    /// and play forever. Clamped to 0..3600 each (a one-hour cap).
    func setStartDelay(_ sec: Double, for voiceIndex: Int) {
        guard voices.indices.contains(voiceIndex) else { return }
        voices[voiceIndex].startDelaySec = max(0, min(3600, sec))
    }
    func setPlayDuration(_ sec: Double, for voiceIndex: Int) {
        guard voices.indices.contains(voiceIndex) else { return }
        voices[voiceIndex].playDurationSec = max(0, min(3600, sec))
    }

    /// 1.0 = no drive; up to ~12 for heavy saturation. Lower-only clamp so
    /// negative values can't invert the waveshaper.
    func setDrive(_ d: Double, for voiceIndex: Int) {
        guard voices.indices.contains(voiceIndex) else { return }
        voices[voiceIndex].drive = max(1.0, min(12.0, d))
    }

    // MARK: - Granular (only active when waveform == .granular)
    func setGrainSize(_ ms: Double, for voiceIndex: Int) {
        guard voices.indices.contains(voiceIndex) else { return }
        voices[voiceIndex].grainSizeMs = max(GrainState.sizeMinMs, min(GrainState.sizeMaxMs, ms))
    }
    func setGrainDensity(_ hz: Double, for voiceIndex: Int) {
        guard voices.indices.contains(voiceIndex) else { return }
        voices[voiceIndex].grainDensityHz = max(GrainState.densityMin, min(GrainState.densityMax, hz))
    }
    func setGrainJitter(_ j: Double, for voiceIndex: Int) {
        guard voices.indices.contains(voiceIndex) else { return }
        voices[voiceIndex].grainJitter = max(0, min(1, j))
    }
    func setGrainPanSpread(_ s: Double, for voiceIndex: Int) {
        guard voices.indices.contains(voiceIndex) else { return }
        voices[voiceIndex].grainPanSpread = max(0, min(1, s))
    }

    // MARK: - Sample play-window (only audible when waveform == .sample)
    func setSampleStart(_ frac: Double, for voiceIndex: Int) {
        guard voices.indices.contains(voiceIndex) else { return }
        voices[voiceIndex].sampleStartFrac = max(0, min(0.999, frac))
    }
    func setSampleEnd(_ frac: Double, for voiceIndex: Int) {
        guard voices.indices.contains(voiceIndex) else { return }
        voices[voiceIndex].sampleEndFrac = max(0.001, min(1, frac))
    }
    func setSampleFadeIn(_ sec: Double, for voiceIndex: Int) {
        guard voices.indices.contains(voiceIndex) else { return }
        voices[voiceIndex].sampleFadeInSec = max(0, min(10, sec))
    }
    func setSampleFadeOut(_ sec: Double, for voiceIndex: Int) {
        guard voices.indices.contains(voiceIndex) else { return }
        voices[voiceIndex].sampleFadeOutSec = max(0, min(10, sec))
    }

    func setReverbDecay(_ sec: Double, for voiceIndex: Int) {
        guard voices.indices.contains(voiceIndex) else { return }
        voices[voiceIndex].reverbDecaySec = max(ReverbState.decayMin, min(ReverbState.decayMax, sec))
    }
    func setReverbMix(_ mix: Double, for voiceIndex: Int) {
        guard voices.indices.contains(voiceIndex) else { return }
        voices[voiceIndex].reverbMix = Float(max(0, min(1, mix)))
    }
    func setDelayTime(_ sec: Double, for voiceIndex: Int) {
        guard voices.indices.contains(voiceIndex) else { return }
        voices[voiceIndex].delayTimeSec = max(DelayState.timeMin, min(DelayState.timeMax, sec))
    }
    func setDelayFeedback(_ fb: Double, for voiceIndex: Int) {
        guard voices.indices.contains(voiceIndex) else { return }
        voices[voiceIndex].delayFeedback = Float(max(0, min(DelayState.feedbackMax, fb)))
    }
    func setDelayMix(_ mix: Double, for voiceIndex: Int) {
        guard voices.indices.contains(voiceIndex) else { return }
        voices[voiceIndex].delayMix = Float(max(0, min(1, mix)))
    }
    func setDelayMode(_ mode: DelayState.Mode, for voiceIndex: Int) {
        guard voices.indices.contains(voiceIndex) else { return }
        let voiceMode: Voice.DelayMode
        switch mode {
        case .mono:     voiceMode = .mono
        case .stereo:   voiceMode = .stereo
        case .pingPong: voiceMode = .pingPong
        }
        voices[voiceIndex].delayMode = voiceMode
    }

    // ── Chorus ───────────────────────────────────────────
    func setChorusRate(_ hz: Double, for voiceIndex: Int) {
        guard voices.indices.contains(voiceIndex) else { return }
        voices[voiceIndex].chorusRateHz = max(ChorusState.rateMin, min(ChorusState.rateMax, hz))
    }
    func setChorusDepth(_ depth: Double, for voiceIndex: Int) {
        guard voices.indices.contains(voiceIndex) else { return }
        voices[voiceIndex].chorusDepth = max(0, min(1, depth))
    }
    func setChorusWidth(_ width: Double, for voiceIndex: Int) {
        guard voices.indices.contains(voiceIndex) else { return }
        voices[voiceIndex].chorusWidth = max(0, min(1, width))
    }
    func setChorusMix(_ mix: Double, for voiceIndex: Int) {
        guard voices.indices.contains(voiceIndex) else { return }
        voices[voiceIndex].chorusMix = Float(max(0, min(1, mix)))
    }

    // ── FM (cross-osc) ───────────────────────────────────
    /// Pass -1 to disable. Self-modulation is silently disabled.
    func setFMSource(_ sourceIndex: Int, for voiceIndex: Int) {
        guard voices.indices.contains(voiceIndex) else { return }
        var src = sourceIndex
        if src == voiceIndex { src = -1 }
        voices[voiceIndex].fmSourceIndex = src
    }
    func setFMIndex(_ index: Double, for voiceIndex: Int) {
        guard voices.indices.contains(voiceIndex) else { return }
        voices[voiceIndex].fmIndex = max(0, min(FMState.indexMax, index))
    }

    /// Load an audio file into a voice's sample slot. The file is decoded with
    /// AVAudioFile, downmixed to mono, and stored as a Float buffer that the
    /// render loop reads with linear interpolation. Throws on decode failure.
    func loadSample(from url: URL, for voiceIndex: Int) throws {
        guard voices.indices.contains(voiceIndex) else { return }
        let file = try AVAudioFile(forReading: url)
        let format = file.processingFormat
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format,
                                            frameCapacity: AVAudioFrameCount(file.length)) else {
            throw NSError(domain: "DroneMeditations.loadSample", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "Could not allocate buffer"])
        }
        try file.read(into: buffer)

        let frameCount = Int(buffer.frameLength)
        guard frameCount > 0, let chData = buffer.floatChannelData else {
            throw NSError(domain: "DroneMeditations.loadSample", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "Empty audio buffer"])
        }
        let channelCount = Int(buffer.format.channelCount)
        var mono = [Float]()
        mono.reserveCapacity(frameCount)
        if channelCount == 1 {
            for i in 0..<frameCount { mono.append(chData[0][i]) }
        } else {
            // Downmix by simple average.
            let inv = Float(1.0) / Float(channelCount)
            for i in 0..<frameCount {
                var sum: Float = 0
                for c in 0..<channelCount { sum += chData[c][i] }
                mono.append(sum * inv)
            }
        }
        voices[voiceIndex].sampleData = mono
        voices[voiceIndex].sampleNativeRate = format.sampleRate
    }

    func clearSample(for voiceIndex: Int) {
        guard voices.indices.contains(voiceIndex) else { return }
        voices[voiceIndex].sampleData = nil
    }
}
