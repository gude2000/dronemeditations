import Foundation
import AVFoundation

/// Owns AVAudioEngine and four `Voice` oscillators. UI code updates voice targets;
/// the engine's source node renders sample-accurate sine/triangle/saw/square audio
/// with smoothed parameter ramps.
final class AudioEngine {
    let engine = AVAudioEngine()
    let voices: [Voice]
    let sampleRate: Double

    /// Master output level (0..1). Settable from UI; the engine's main mixer holds the value.
    var masterVolume: Float {
        get { engine.mainMixerNode.outputVolume }
        set { engine.mainMixerNode.outputVolume = max(0, min(1, newValue)) }
    }

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
        // can hit the soft-limiter and audibly compress.
        engine.mainMixerNode.outputVolume = 0.30
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
            for v in voices {
                v.effectiveEnabled = anySoloed ? v.isSoloed : true
                v.render(frameCount: n, left: left, right: right)
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
              (0..<3).contains(lfoIndex) else { return }
        let clamped = max(LfoState.rateMin, min(LfoState.rateMax, hz))
        voices[voiceIndex].lfoRatesHz[lfoIndex] = clamped
    }

    func setLfoDepth(_ depth: Double, for voiceIndex: Int, lfoIndex: Int) {
        guard voices.indices.contains(voiceIndex),
              (0..<3).contains(lfoIndex) else { return }
        voices[voiceIndex].lfoDepths[lfoIndex] = max(0, min(1, depth))
    }

    func setLfoShape(_ shape: LfoState.Shape, for voiceIndex: Int, lfoIndex: Int) {
        guard voices.indices.contains(voiceIndex),
              (0..<3).contains(lfoIndex) else { return }
        voices[voiceIndex].lfoShapes[lfoIndex] = shape
    }

    func setLfoTarget(_ target: LfoState.Target, for voiceIndex: Int, lfoIndex: Int) {
        guard voices.indices.contains(voiceIndex),
              (0..<3).contains(lfoIndex) else { return }
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
