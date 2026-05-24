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
    @Published var masterVolume: Double = 0.65
    @Published var showControls: Bool = true
    @Published var activePresetName: String? = nil
    /// True if Chladni overlay is drawn over the blob background.
    @Published var showChladni: Bool = true

    @Published var userPresets: [UserPreset] = UserPresetStore.load()

    let audioEngine: AudioEngine
    let controller: DroneController

    private var cancellables = Set<AnyCancellable>()

    init() {
        let engine = AudioEngine()
        self.audioEngine = engine
        self.controller = DroneController(engine: engine)
        pushAllOscillatorsToEngine()
        audioEngine.masterVolume = Float(masterVolume)
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
            for (k, l) in v.lfos.enumerated() where k < 3 {
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
}
