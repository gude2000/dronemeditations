import Foundation
import Combine
import SwiftUI

/// The single source of truth for the UI.
/// Owns the audio engine and pushes parameter changes through to it.
@MainActor
final class DroneViewModel: ObservableObject {
    // MARK: - Per-oscillator state (mirrors the audio voices)
    @Published var oscillators: [OscillatorState] = OscillatorState.defaults()

    // MARK: - Chord generator state
    @Published var currentKey: PitchClass = .a
    @Published var currentOctave: Int = 3
    @Published var currentChord: ChordType = ChordType.all[0]
    @Published var currentTuning: TuningSystem = .equal12

    // MARK: - Master + UI
    @Published var masterVolume: Double = 0.30
    @Published var showControls: Bool = true
    @Published var activePresetName: String? = nil
    /// True if Chladni overlay is drawn over the blob background.
    @Published var showChladni: Bool = true

    @Published var userPresets: [UserPreset] = UserPresetStore.load()

    /// True while generative slow-drift mode is running. Voices wander
    /// gently (±half-semitone freq, ±0.3 pan, ±0.15 amp) around their
    /// values at the moment drift was turned on. Toggled by `toggleDrift()`.
    @Published private(set) var isDriftEnabled: Bool = false

    let audioEngine: AudioEngine
    let controller: DroneController

    /// Bridges to MPNowPlayingInfoCenter + MPRemoteCommandCenter so the
    /// lock screen, Control Center, and EarPods/AirPods buttons can drive
    /// transport. Created in init; refresh() called from didChange Combine
    /// pipelines below.
    private(set) var nowPlaying: NowPlayingBridge!

    /// Mic-driven pitch detection ("tune to room"). Lazily reconfigures the
    /// audio session for input on first start; restores playback-only when
    /// stopped so the mic indicator doesn't linger.
    private(set) var micPitch: MicPitchDetector!

    private var cancellables = Set<AnyCancellable>()

    init() {
        let engine = AudioEngine()
        self.audioEngine = engine
        self.controller = DroneController(engine: engine)
        pushAllOscillatorsToEngine()
        audioEngine.masterVolume = Float(masterVolume)
        self.nowPlaying = NowPlayingBridge(controller: controller, vm: self)
        self.micPitch = MicPitchDetector(engine: engine)

        // Mirror transport + preset changes into Now Playing.
        controller.$state.sink { [weak self] _ in
            Task { @MainActor in self?.nowPlaying.refresh() }
        }.store(in: &cancellables)
        controller.$elapsed.sink { [weak self] _ in
            Task { @MainActor in self?.nowPlaying.refresh() }
        }.store(in: &cancellables)
        controller.$sessionDuration.sink { [weak self] _ in
            Task { @MainActor in self?.nowPlaying.refresh() }
        }.store(in: &cancellables)
        $activePresetName.sink { [weak self] _ in
            Task { @MainActor in self?.nowPlaying.refresh() }
        }.store(in: &cancellables)
    }

    // MARK: - Per-oscillator mutators

    func setFrequency(_ hz: Double, for index: Int) {
        guard oscillators.indices.contains(index) else { return }
        let clamped = max(OscillatorState.minFrequency, min(OscillatorState.maxFrequency, hz))
        oscillators[index].frequencyHz = clamped
        audioEngine.setFrequency(clamped, for: index)
        activePresetName = nil
    }

    func setWaveform(_ wf: Waveform, for index: Int) {
        guard oscillators.indices.contains(index) else { return }
        oscillators[index].waveform = wf
        audioEngine.setWaveform(wf, for: index)
    }

    func setAmplitude(_ amp: Double, for index: Int) {
        guard oscillators.indices.contains(index) else { return }
        oscillators[index].amplitude = max(0, min(1, amp))
        audioEngine.setAmplitude(oscillators[index].amplitude, for: index)
    }

    func setPan(_ pan: Double, for index: Int) {
        guard oscillators.indices.contains(index) else { return }
        oscillators[index].pan = max(-1, min(1, pan))
        audioEngine.setPan(oscillators[index].pan, for: index)
    }

    func toggleMute(_ index: Int) {
        guard oscillators.indices.contains(index) else { return }
        oscillators[index].isMuted.toggle()
        audioEngine.setMute(oscillators[index].isMuted, for: index)
    }

    func toggleSolo(_ index: Int) {
        guard oscillators.indices.contains(index) else { return }
        oscillators[index].isSoloed.toggle()
        audioEngine.setSolo(oscillators[index].isSoloed, for: index)
    }

    func setLfoRate(_ hz: Double, for index: Int, lfoIndex: Int) {
        guard oscillators.indices.contains(index),
              oscillators[index].lfos.indices.contains(lfoIndex) else { return }
        let clamped = max(LfoState.rateMin, min(LfoState.rateMax, hz))
        oscillators[index].lfos[lfoIndex].rateHz = clamped
        audioEngine.setLfoRate(clamped, for: index, lfoIndex: lfoIndex)
    }

    func setLfoDepth(_ depth: Double, for index: Int, lfoIndex: Int) {
        guard oscillators.indices.contains(index),
              oscillators[index].lfos.indices.contains(lfoIndex) else { return }
        let prevTarget = oscillators[index].lfos[lfoIndex].target
        let wasActive = oscillators[index].lfos[lfoIndex].depth > 0
        let clamped = max(0, min(1, depth))
        oscillators[index].lfos[lfoIndex].depth = clamped
        audioEngine.setLfoDepth(clamped, for: index, lfoIndex: lfoIndex)
        if wasActive && clamped == 0 { restoreLfoBase(for: index, target: prevTarget) }
    }

    func setLfoShape(_ shape: LfoState.Shape, for index: Int, lfoIndex: Int) {
        guard oscillators.indices.contains(index),
              oscillators[index].lfos.indices.contains(lfoIndex) else { return }
        oscillators[index].lfos[lfoIndex].shape = shape
        audioEngine.setLfoShape(shape, for: index, lfoIndex: lfoIndex)
    }

    func setLfoTarget(_ target: LfoState.Target, for index: Int, lfoIndex: Int) {
        guard oscillators.indices.contains(index),
              oscillators[index].lfos.indices.contains(lfoIndex) else { return }
        let prevTarget = oscillators[index].lfos[lfoIndex].target
        oscillators[index].lfos[lfoIndex].target = target
        audioEngine.setLfoTarget(target, for: index, lfoIndex: lfoIndex)
        if prevTarget != target { restoreLfoBase(for: index, target: prevTarget) }
    }

    func setFilterType(_ type: FilterState.FilterType, for index: Int) {
        guard oscillators.indices.contains(index) else { return }
        oscillators[index].filter.type = type
        audioEngine.setFilterType(type, for: index)
    }

    func setFilterCutoff(_ hz: Double, for index: Int) {
        guard oscillators.indices.contains(index) else { return }
        let clamped = max(FilterState.cutoffMin, min(FilterState.cutoffMax, hz))
        oscillators[index].filter.cutoffHz = clamped
        audioEngine.setFilterCutoff(clamped, for: index)
    }

    func setFilterQ(_ q: Double, for index: Int) {
        guard oscillators.indices.contains(index) else { return }
        let clamped = max(FilterState.qMin, min(FilterState.qMax, q))
        oscillators[index].filter.q = clamped
        audioEngine.setFilterQ(clamped, for: index)
    }

    func setReverbDecay(_ sec: Double, for index: Int) {
        guard oscillators.indices.contains(index) else { return }
        let clamped = max(ReverbState.decayMin, min(ReverbState.decayMax, sec))
        oscillators[index].reverb.decaySec = clamped
        audioEngine.setReverbDecay(clamped, for: index)
    }
    func setReverbMix(_ mix: Double, for index: Int) {
        guard oscillators.indices.contains(index) else { return }
        let clamped = max(0, min(1, mix))
        oscillators[index].reverb.mix = clamped
        audioEngine.setReverbMix(clamped, for: index)
    }
    func setDelayTime(_ sec: Double, for index: Int) {
        guard oscillators.indices.contains(index) else { return }
        let clamped = max(DelayState.timeMin, min(DelayState.timeMax, sec))
        oscillators[index].delay.timeSec = clamped
        audioEngine.setDelayTime(clamped, for: index)
    }
    func setDelayFeedback(_ fb: Double, for index: Int) {
        guard oscillators.indices.contains(index) else { return }
        let clamped = max(0, min(DelayState.feedbackMax, fb))
        oscillators[index].delay.feedback = clamped
        audioEngine.setDelayFeedback(clamped, for: index)
    }
    func setDelayMix(_ mix: Double, for index: Int) {
        guard oscillators.indices.contains(index) else { return }
        let clamped = max(0, min(1, mix))
        oscillators[index].delay.mix = clamped
        audioEngine.setDelayMix(clamped, for: index)
    }

    /// Load an audio file from a URL into a voice's sample slot, and switch the
    /// voice's waveform to `.sample` so it plays. Also persists the file into
    /// `Documents/DroneSamples/` so it can be referenced by future preset
    /// saves and reloaded across launches. Throws if decoding fails.
    func loadSample(from url: URL, for index: Int) throws {
        guard oscillators.indices.contains(index) else { return }
        let storedName = try UserPresetStore.persistSample(from: url)
        let storedURL = UserPresetStore.samplesDirectory.appendingPathComponent(storedName)
        try audioEngine.loadSample(from: storedURL, for: index)
        oscillators[index].sampleName = url.lastPathComponent
        oscillators[index].sampleStoredFilename = storedName
        oscillators[index].waveform = .sample
        audioEngine.setWaveform(.sample, for: index)
    }

    func clearSample(for index: Int) {
        guard oscillators.indices.contains(index) else { return }
        audioEngine.clearSample(for: index)
        oscillators[index].sampleName = nil
        oscillators[index].sampleStoredFilename = nil
        if oscillators[index].waveform == .sample {
            oscillators[index].waveform = .sine
            audioEngine.setWaveform(.sine, for: index)
        }
    }

    // MARK: - User presets

    func saveCurrentAsUserPreset(named name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        let voices = oscillators.map { o in
            UserPreset.Voice(
                frequencyHz: o.frequencyHz, waveform: o.waveform,
                amplitude: o.amplitude, pan: o.pan,
                isMuted: o.isMuted, isSoloed: o.isSoloed,
                filter: o.filter, reverb: o.reverb, delay: o.delay,
                lfos: o.lfos, sampleStoredFilename: o.sampleStoredFilename
            )
        }
        let preset = UserPreset(
            id: UserPreset.newId(), name: trimmed, createdAt: Date(),
            keyId: currentKey.rawValue, octave: currentOctave,
            chordId: currentChord.id, tuningId: currentTuning.id,
            masterVolume: masterVolume,
            oscillators: voices
        )
        userPresets.insert(preset, at: 0)
        UserPresetStore.save(userPresets)
        activePresetName = preset.name
    }

    func loadUserPreset(id: String) {
        guard let preset = userPresets.first(where: { $0.id == id }) else { return }
        if let key = PitchClass(rawValue: preset.keyId) { currentKey = key }
        currentOctave = preset.octave
        if let chord = ChordType.all.first(where: { $0.id == preset.chordId }) { currentChord = chord }
        if let tuning = TuningSystem(rawValue: preset.tuningId) { currentTuning = tuning }
        setMasterVolume(preset.masterVolume)
        for (i, v) in preset.oscillators.enumerated() where i < 4 {
            setFrequency(v.frequencyHz, for: i)
            setAmplitude(v.amplitude, for: i)
            setPan(v.pan, for: i)
            if oscillators[i].isMuted != v.isMuted { toggleMute(i) }
            if oscillators[i].isSoloed != v.isSoloed { toggleSolo(i) }
            setFilterType(v.filter.type, for: i)
            setFilterCutoff(v.filter.cutoffHz, for: i)
            setFilterQ(v.filter.q, for: i)
            setReverbDecay(v.reverb.decaySec, for: i)
            setReverbMix(v.reverb.mix, for: i)
            setDelayTime(v.delay.timeSec, for: i)
            setDelayFeedback(v.delay.feedback, for: i)
            setDelayMix(v.delay.mix, for: i)
            // Pad with default LFO 4 (sine→pitch) for presets saved before LFO 4 existed.
            var loadedLfos = v.lfos
            while loadedLfos.count < 4 {
                loadedLfos.append(LfoState(shape: .sine, target: .pitch, rateHz: 0.30, depth: 0))
            }
            for (k, l) in loadedLfos.enumerated() where k < 4 {
                setLfoShape(l.shape, for: i, lfoIndex: k)
                setLfoTarget(l.target, for: i, lfoIndex: k)
                setLfoRate(l.rateHz, for: i, lfoIndex: k)
                setLfoDepth(l.depth, for: i, lfoIndex: k)
            }
            clearSample(for: i)
            if let stored = v.sampleStoredFilename,
               let url = UserPresetStore.url(forStoredSample: stored) {
                do {
                    try audioEngine.loadSample(from: url, for: i)
                    oscillators[i].sampleName = stored
                    oscillators[i].sampleStoredFilename = stored
                    oscillators[i].waveform = .sample
                    audioEngine.setWaveform(.sample, for: i)
                } catch {
                    print("Couldn't reload sample for preset: \(error)")
                }
            } else if v.waveform != .sample {
                setWaveform(v.waveform, for: i)
            }
        }
        activePresetName = preset.name
    }

    func deleteUserPreset(id: String) {
        guard let preset = userPresets.first(where: { $0.id == id }) else { return }
        let storedNames = preset.oscillators.compactMap { $0.sampleStoredFilename }
        userPresets.removeAll { $0.id == id }
        UserPresetStore.save(userPresets)
        for n in storedNames { UserPresetStore.deleteSampleIfUnused(n, presets: userPresets) }
        if activePresetName == preset.name { activePresetName = nil }
    }

    private func restoreLfoBase(for index: Int, target: LfoState.Target) {
        let o = oscillators[index]
        switch target {
        case .pan:       audioEngine.setPan(o.pan, for: index)
        case .amplitude: audioEngine.setAmplitude(o.amplitude, for: index)
        case .cutoff:    audioEngine.setFilterCutoff(o.filter.cutoffHz, for: index)
        case .pitch:     audioEngine.setFrequency(o.frequencyHz, for: index)
        }
    }

    // MARK: - Chord / tuning / key

    func setKey(_ key: PitchClass) {
        currentKey = key
        applyCurrentChord()
    }

    func setOctave(_ octave: Int) {
        currentOctave = max(0, min(7, octave))
        applyCurrentChord()
    }

    func setChord(_ chord: ChordType) {
        currentChord = chord
        applyCurrentChord()
    }

    func setTuning(_ tuning: TuningSystem) {
        currentTuning = tuning
        applyCurrentChord()
    }

    func applyCurrentChord() {
        let rootHz = Pitch(currentKey, octave: currentOctave).frequencyEqual12()
        let freqs = currentChord.frequencies(rootHz: rootHz, tuning: currentTuning)
        for i in 0..<min(4, freqs.count) {
            let clamped = max(OscillatorState.minFrequency, min(OscillatorState.maxFrequency, freqs[i]))
            oscillators[i].frequencyHz = clamped
            audioEngine.setFrequency(clamped, for: i)
        }
        activePresetName = nil
    }

    // MARK: - Preset

    func applyPreset(_ preset: Preset) {
        for (i, voice) in preset.voices.enumerated() where i < 4 {
            let clamped = max(OscillatorState.minFrequency, min(OscillatorState.maxFrequency, voice.hz))
            oscillators[i].frequencyHz = clamped
            oscillators[i].pan = voice.pan
            // Silent padding voices: mute them so the preset is clean.
            let isSilentSlot = (preset.voices.count > i) &&
                (preset.category == .binaural2 && i >= 2) ||
                (preset.category == .binaural3 && i >= 3) ||
                (preset.category == .solfeggio && voice.hz == 110.0 && voice.pan == 0.0 && i == 3)
            oscillators[i].isMuted = isSilentSlot
            audioEngine.setFrequency(clamped, for: i)
            audioEngine.setPan(voice.pan, for: i)
            audioEngine.setMute(isSilentSlot, for: i)
        }
        activePresetName = preset.name
    }

    // MARK: - Master

    func setMasterVolume(_ v: Double) {
        masterVolume = max(0, min(1, v))
        audioEngine.masterVolume = Float(masterVolume)
    }

    // MARK: - Helpers

    private func pushAllOscillatorsToEngine() {
        for osc in oscillators {
            audioEngine.setFrequency(osc.frequencyHz, for: osc.id)
            audioEngine.setAmplitude(osc.amplitude, for: osc.id)
            audioEngine.setPan(osc.pan, for: osc.id)
            audioEngine.setWaveform(osc.waveform, for: osc.id)
            audioEngine.setMute(osc.isMuted, for: osc.id)
            audioEngine.setSolo(osc.isSoloed, for: osc.id)
            audioEngine.setFilterType(osc.filter.type, for: osc.id)
            audioEngine.setFilterCutoff(osc.filter.cutoffHz, for: osc.id)
            audioEngine.setFilterQ(osc.filter.q, for: osc.id)
            audioEngine.setReverbDecay(osc.reverb.decaySec, for: osc.id)
            audioEngine.setReverbMix(osc.reverb.mix, for: osc.id)
            audioEngine.setDelayTime(osc.delay.timeSec, for: osc.id)
            audioEngine.setDelayFeedback(osc.delay.feedback, for: osc.id)
            audioEngine.setDelayMix(osc.delay.mix, for: osc.id)
            for (i, lfo) in osc.lfos.enumerated() {
                audioEngine.setLfoShape(lfo.shape, for: osc.id, lfoIndex: i)
                audioEngine.setLfoTarget(lfo.target, for: osc.id, lfoIndex: i)
                audioEngine.setLfoRate(lfo.rateHz, for: osc.id, lfoIndex: i)
                audioEngine.setLfoDepth(lfo.depth, for: osc.id, lfoIndex: i)
            }
        }
    }

    // MARK: - Frequency / octave helpers

    /// Available octave range for the key picker.
    static let octaveRange: ClosedRange<Int> = 1...6

    // MARK: - Randomize an oscillator

    /// Randomize this voice's parameters — everything except amplitude/level
    /// so the voice doesn't suddenly blast or vanish. Mirrors the web
    /// `randomizeOscillator` action so both apps produce comparable results.
    func randomizeOscillator(_ index: Int) {
        guard index >= 0 && index < oscillators.count else { return }

        // Frequency — log-uniform across the meditation drone range.
        let lo = log2(60.0), hi = log2(800.0)
        setFrequency(pow(2.0, lo + Double.random(in: 0...1) * (hi - lo)), for: index)

        // Waveform — non-sample so silent slots aren't created accidentally.
        let waveforms: [Waveform] = [.sine, .triangle, .sawtooth, .square]
        setWaveform(waveforms.randomElement()!, for: index)

        // Pan — keep slightly inside [-1, 1] so center-clustered presets feel
        // distinct from full hard-pan ones.
        oscillators[index].pan = Double.random(in: -0.85...0.85)
        audioEngine.setPan(oscillators[index].pan, for: index)

        // Filter type + log-uniform cutoff + modest Q.
        let filterTypes: [FilterState.FilterType] = [.lowpass, .highpass, .bandpass]
        setFilterType(filterTypes.randomElement()!, for: index)
        let fLo = log2(200.0), fHi = log2(6000.0)
        setFilterCutoff(pow(2.0, fLo + Double.random(in: 0...1) * (fHi - fLo)), for: index)
        setFilterQ(Double.random(in: 0.5...3.0), for: index)

        // Reverb + delay — lush but bounded.
        setReverbDecay(Double.random(in: 0.5...6.0), for: index)
        setReverbMix(Double.random(in: 0...0.5), for: index)
        setDelayTime(Double.random(in: 0.08...0.8), for: index)
        setDelayFeedback(Double.random(in: 0...0.5), for: index)
        setDelayMix(Double.random(in: 0...0.4), for: index)

        // LFOs — random shape + target, slow rate, modest depth.
        let shapes: [LfoState.Shape] = [.sine, .triangle, .square, .sampleAndHold]
        let targets: [LfoState.Target] = [.pan, .amplitude, .cutoff, .pitch]
        for lfo in 0..<oscillators[index].lfos.count {
            setLfoShape(shapes.randomElement()!, for: index, lfoIndex: lfo)
            setLfoTarget(targets.randomElement()!, for: index, lfoIndex: lfo)
            setLfoRate(Double.random(in: 0.05...1.5), for: index, lfoIndex: lfo)
            setLfoDepth(Double.random(in: 0...0.6), for: index, lfoIndex: lfo)
        }

        // We've drifted away from any preset.
        activePresetName = nil
    }

    // MARK: - Generative drift mode

    /// Per-voice drift state: baseline values captured at toggle-on time,
    /// current targets, and the next retarget timestamp (in seconds since
    /// drift started). Keeps the wander musically anchored to the starting
    /// preset instead of letting it run away over a long session.
    private struct DriftVoice {
        var baseFreq: Double, basePan: Double, baseAmp: Double
        var freqTarget: Double, panTarget: Double, ampTarget: Double
        var nextRetargetAt: Date
    }
    private var driftVoices: [DriftVoice] = []
    private var driftTimer: Timer?

    func toggleDrift() {
        if isDriftEnabled { stopDrift() } else { startDrift() }
    }

    private func startDrift() {
        driftVoices = oscillators.map {
            DriftVoice(
                baseFreq: $0.frequencyHz, basePan: $0.pan, baseAmp: $0.amplitude,
                freqTarget: $0.frequencyHz, panTarget: $0.pan, ampTarget: $0.amplitude,
                nextRetargetAt: .distantPast
            )
        }
        isDriftEnabled = true
        driftTimer?.invalidate()
        driftTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.driftTick() }
        }
    }

    private func stopDrift() {
        driftTimer?.invalidate()
        driftTimer = nil
        isDriftEnabled = false
        driftVoices.removeAll()
    }

    /// One drift step: per voice, occasionally pick new targets within the
    /// bounded "humming around the preset" range, then lerp the current
    /// values toward those targets so motion is glacial and continuous.
    private func driftTick() {
        let now = Date()
        let lerp = 0.05
        for i in 0..<driftVoices.count {
            guard i < oscillators.count else { continue }
            var v = driftVoices[i]
            let o = oscillators[i]

            if now >= v.nextRetargetAt {
                let cents = (Double.random(in: -1...1)) * 50.0    // ±50 cents from base
                v.freqTarget = v.baseFreq * pow(2.0, cents / 1200.0)
                v.panTarget  = max(-1, min(1, v.basePan + Double.random(in: -0.3...0.3)))
                v.ampTarget  = max(0.1, min(1, v.baseAmp + Double.random(in: -0.15...0.15)))
                v.nextRetargetAt = now.addingTimeInterval(30 + Double.random(in: 0...30))
            }

            let newFreq = o.frequencyHz + (v.freqTarget - o.frequencyHz) * lerp
            let newPan  = o.pan         + (v.panTarget  - o.pan)         * lerp
            let newAmp  = o.amplitude   + (v.ampTarget  - o.amplitude)   * lerp

            oscillators[i].frequencyHz = newFreq
            oscillators[i].pan = newPan
            oscillators[i].amplitude = newAmp
            audioEngine.setFrequency(newFreq, for: i)
            audioEngine.setPan(newPan, for: i)
            audioEngine.setAmplitude(newAmp, for: i)
            driftVoices[i] = v
        }
    }
}
