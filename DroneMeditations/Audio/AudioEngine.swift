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
        // Reasonable default headroom so a fortissimo chord doesn't clip.
        engine.mainMixerNode.outputVolume = 0.65
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
}
