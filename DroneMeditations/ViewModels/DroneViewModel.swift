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
    /// True if the FFT spectrum analyzer is drawn over the blob background.
    @Published var showSpectrum: Bool = false {
        didSet {
            if showSpectrum { spectrumTap.start() } else { spectrumTap.stop() }
        }
    }
    /// Cymatics-only Performance fullscreen — hides every chrome element
    /// (controls, mini-strip, tap hint, copyright) leaving only the pattern
    /// and a tiny Exit affordance.
    @Published var performanceMode: Bool = false

    // ─── Meditation journey state ───
    @Published private(set) var activeJourneyId: String? = nil
    @Published private(set) var journeyStageIndex: Int = 0
    @Published private(set) var journeyStageEndsAt: Date? = nil
    private var journeyTimer: Timer?

    var activeJourney: Journey? {
        guard let id = activeJourneyId else { return nil }
        return Journey.all.first { $0.id == id }
    }

    @Published var userPresets: [UserPreset] = UserPresetStore.load()
    /// Per-voice presets — capture/restore a single oscillator's full state
    /// so favorite voices can be mixed and matched across the four slots.
    @Published var voicePresets: [VoicePreset] = VoicePresetStore.load()

    /// A scene is the per-voice drift assignment for all four oscillators.
    /// Scenes are *templates* — picking one bulk-copies its voice configs
    /// into the per-oscillator state. Users can then customize any voice
    /// via the per-strip drift menu and the header pill flips to "Custom".
    struct DriftScene: Identifiable {
        let id: String
        let name: String
        let hint: String
        let voices: [DriftVoiceConfig]   // length 4
        let isCoordinated: Bool          // true for multi-voice scenes (shows under divider)
    }

    static let driftScenes: [DriftScene] = {
        func cfg(_ pitchMode: DriftVoiceConfig.PitchMode = .static,
                 _ pitchAmount: Double = 1.0,
                 _ pitchPhase: Double = 0,
                 panMode: DriftVoiceConfig.PanMode = .static,
                 panAmount: Double = 1.0,
                 panPhase: Double = 0) -> DriftVoiceConfig {
            DriftVoiceConfig(pitchMode: pitchMode, pitchAmount: pitchAmount,
                             pitchPhase: pitchPhase,
                             panMode: panMode, panAmount: panAmount, panPhase: panPhase)
        }
        return [
            // Singles
            DriftScene(id: "off",     name: "Off",         hint: "No drift",
                       voices: Array(repeating: cfg(), count: 4), isCoordinated: false),
            DriftScene(id: "glacial", name: "Glacial",     hint: "Gentle random wander on all voices",
                       voices: Array(repeating: cfg(.glacial, panMode: .glacial), count: 4),
                       isCoordinated: false),
            DriftScene(id: "ascend",  name: "All Ascend",  hint: "Every voice climbs an octave",
                       voices: Array(repeating: cfg(.up, 1), count: 4), isCoordinated: false),
            DriftScene(id: "descend", name: "All Descend", hint: "Every voice falls an octave",
                       voices: Array(repeating: cfg(.down, 1), count: 4), isCoordinated: false),
            DriftScene(id: "downUp",  name: "All Down/Up", hint: "Every voice falls then returns",
                       voices: Array(repeating: cfg(.downUp, 1), count: 4), isCoordinated: false),
            DriftScene(id: "upDown",  name: "All Up/Down", hint: "Every voice rises then returns",
                       voices: Array(repeating: cfg(.upDown, 1), count: 4), isCoordinated: false),
            // Coordinated
            DriftScene(id: "divergence", name: "Divergence",
                       hint: "2 voices up, 2 voices down",
                       voices: [cfg(.up, 1), cfg(.down, 1), cfg(.up, 1), cfg(.down, 1)],
                       isCoordinated: true),
            DriftScene(id: "convergence", name: "Convergence",
                       hint: "Outer voices drift toward middle",
                       voices: [cfg(.down, 0.5), cfg(), cfg(), cfg(.up, 0.5)],
                       isCoordinated: true),
            DriftScene(id: "crossing", name: "Crossing Paths",
                       hint: "Pairs of V and ^ that cross at session mid",
                       voices: [cfg(.downUp, 1), cfg(.upDown, 1),
                                cfg(.downUp, 1, 0.25), cfg(.upDown, 1, 0.25)],
                       isCoordinated: true),
            DriftScene(id: "pendulum", name: "Pendulum",
                       hint: "Outer voices swing pan + pitch; inner pair holds center",
                       voices: [cfg(.up, 0.5, panMode: .pendulum),
                                cfg(),
                                cfg(),
                                cfg(.down, 0.5, panMode: .antiPendulum)],
                       isCoordinated: true),
            DriftScene(id: "breathing", name: "Breathing",
                       hint: "Down/Up on all voices, staggered phases",
                       voices: [cfg(.downUp, 0.5, 0.00), cfg(.downUp, 0.5, 0.25),
                                cfg(.downUp, 0.5, 0.50), cfg(.downUp, 0.5, 0.75)],
                       isCoordinated: true),
            DriftScene(id: "spiral", name: "Spiral",
                       hint: "Up/Down with varying depths — voices spiral around the root",
                       voices: [cfg(.upDown, 1.00),       cfg(.upDown, 0.75, 0.125),
                                cfg(.upDown, 0.50, 0.25), cfg(.upDown, 0.25, 0.375)],
                       isCoordinated: true),
            DriftScene(id: "aurora", name: "Aurora",
                       hint: "Glacial pitch + opposite slow pan sweeps",
                       voices: [cfg(.glacial, panMode: .sweepLR),
                                cfg(.glacial, panMode: .sweepRL),
                                cfg(.glacial, panMode: .pendulum),
                                cfg(.glacial, panMode: .antiPendulum)],
                       isCoordinated: true),
            DriftScene(id: "tidal", name: "Tidal",
                       hint: "Slow sine wave on pitch, opposite pans for swelling space",
                       voices: [cfg(.wave, 0.5, 0,    panMode: .sweepLR),
                                cfg(.wave, 0.5, 0.5,  panMode: .sweepRL),
                                cfg(.wave, 0.5, 0.25, panMode: .sweepLR),
                                cfg(.wave, 0.5, 0.75, panMode: .sweepRL)],
                       isCoordinated: true),
        ]
    }()

    @Published private(set) var driftSceneId: String = "off"
    var driftScene: DriftScene? { Self.driftScenes.first { $0.id == driftSceneId } }

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

    /// Optional subtle haptic feedback synced to the slowest active LFO.
    /// Off by default; user toggles from controls.
    private(set) var haptics: HapticsBridge!

    /// FFT spectrum analyzer source. Off until `showSpectrum` flips true.
    private(set) var spectrumTap: SpectrumTap!

    private var cancellables = Set<AnyCancellable>()

    init() {
        let engine = AudioEngine()
        self.audioEngine = engine
        self.controller = DroneController(engine: engine)
        pushAllOscillatorsToEngine()
        audioEngine.masterVolume = Float(masterVolume)
        self.nowPlaying = NowPlayingBridge(controller: controller, vm: self)
        self.micPitch = MicPitchDetector(engine: engine)
        self.haptics = HapticsBridge(vm: self)
        self.spectrumTap = SpectrumTap(engine: engine)

        // Mirror transport + preset changes into Now Playing, and stop
        // any running journey when transport stops.
        controller.$state.sink { [weak self] newState in
            Task { @MainActor in
                self?.nowPlaying.refresh()
                if newState == .stopped, self?.activeJourneyId != nil {
                    self?.stopJourney()
                }
            }
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
    func setDelayMode(_ mode: DelayState.Mode, for index: Int) {
        guard oscillators.indices.contains(index) else { return }
        oscillators[index].delay.mode = mode
        audioEngine.setDelayMode(mode, for: index)
    }
    func setDelayTiming(_ timing: DelayState.Timing, for index: Int) {
        guard oscillators.indices.contains(index) else { return }
        oscillators[index].delay.timing = timing
        if let sec = timing.seconds() {
            setDelayTime(sec, for: index)
        }
    }

    // ── Chorus ───────────────────────────────────────────
    func setChorusRate(_ hz: Double, for index: Int) {
        guard oscillators.indices.contains(index) else { return }
        let clamped = max(ChorusState.rateMin, min(ChorusState.rateMax, hz))
        oscillators[index].chorus.rateHz = clamped
        audioEngine.setChorusRate(clamped, for: index)
    }
    func setChorusDepth(_ depth: Double, for index: Int) {
        guard oscillators.indices.contains(index) else { return }
        let clamped = max(0, min(1, depth))
        oscillators[index].chorus.depth = clamped
        audioEngine.setChorusDepth(clamped, for: index)
    }
    func setChorusWidth(_ width: Double, for index: Int) {
        guard oscillators.indices.contains(index) else { return }
        let clamped = max(0, min(1, width))
        oscillators[index].chorus.width = clamped
        audioEngine.setChorusWidth(clamped, for: index)
    }
    func setChorusMix(_ mix: Double, for index: Int) {
        guard oscillators.indices.contains(index) else { return }
        let clamped = max(0, min(1, mix))
        oscillators[index].chorus.mix = clamped
        audioEngine.setChorusMix(clamped, for: index)
    }

    // ── FM ───────────────────────────────────────────────
    func setFMSource(_ sourceIndex: Int, for index: Int) {
        guard oscillators.indices.contains(index) else { return }
        let src = sourceIndex == index ? -1 : sourceIndex
        oscillators[index].fm.sourceIndex = src
        audioEngine.setFMSource(src, for: index)
    }
    func setFMIndex(_ value: Double, for index: Int) {
        guard oscillators.indices.contains(index) else { return }
        let clamped = max(0, min(FMState.indexMax, value))
        oscillators[index].fm.index = clamped
        audioEngine.setFMIndex(clamped, for: index)
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
                lfos: o.lfos, sampleStoredFilename: o.sampleStoredFilename,
                fm: o.fm, chorus: o.chorus
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
            // FM + Chorus (optional in preset for backward compatibility).
            let fm = v.fm ?? .defaults()
            let ch = v.chorus ?? .defaults()
            setFMSource(fm.sourceIndex, for: i)
            setFMIndex(fm.index, for: i)
            setChorusRate(ch.rateHz, for: i)
            setChorusDepth(ch.depth, for: i)
            setChorusWidth(ch.width, for: i)
            setChorusMix(ch.mix, for: i)
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

    // MARK: - Per-voice presets

    func saveCurrentVoiceAsPreset(_ index: Int, name: String? = nil) {
        guard index >= 0 && index < oscillators.count else { return }
        let o = oscillators[index]
        let snap = VoicePreset.VoiceSnapshot(
            frequencyHz: o.frequencyHz,
            waveform: o.waveform,
            amplitude: o.amplitude,
            pan: o.pan,
            filter: o.filter,
            reverb: o.reverb,
            delay: o.delay,
            lfos: o.lfos,
            drift: o.drift,
            fm: o.fm,
            chorus: o.chorus
        )
        let trimmed = (name ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let chosenName = trimmed.isEmpty
            ? "\(o.waveform.displayName) \(String(format: "%.1f", o.frequencyHz)) Hz"
            : trimmed
        let preset = VoicePreset(
            id: "voice-" + UUID().uuidString.prefix(8).lowercased(),
            name: chosenName,
            createdAt: Date(),
            voice: snap
        )
        voicePresets.insert(preset, at: 0)
        VoicePresetStore.save(voicePresets)
    }

    func loadVoicePreset(_ index: Int, presetId: String) {
        guard index >= 0 && index < oscillators.count,
              let p = voicePresets.first(where: { $0.id == presetId }) else { return }
        let v = p.voice
        // Mutate model state.
        oscillators[index].frequencyHz = v.frequencyHz
        oscillators[index].waveform = v.waveform
        oscillators[index].amplitude = v.amplitude
        oscillators[index].pan = v.pan
        oscillators[index].filter = v.filter
        oscillators[index].reverb = v.reverb
        oscillators[index].delay = v.delay
        oscillators[index].lfos = v.lfos
        oscillators[index].drift = v.drift
        let loadedFm = v.fm ?? .defaults()
        let loadedCh = v.chorus ?? .defaults()
        oscillators[index].fm = loadedFm
        oscillators[index].chorus = loadedCh
        // Push to engine.
        audioEngine.setFrequency(v.frequencyHz, for: index)
        audioEngine.setWaveform(v.waveform, for: index)
        audioEngine.setAmplitude(v.amplitude, for: index)
        audioEngine.setPan(v.pan, for: index)
        audioEngine.setFilterType(v.filter.type, for: index)
        audioEngine.setFilterCutoff(v.filter.cutoffHz, for: index)
        audioEngine.setFilterQ(v.filter.q, for: index)
        audioEngine.setFMSource(loadedFm.sourceIndex, for: index)
        audioEngine.setFMIndex(loadedFm.index, for: index)
        audioEngine.setChorusRate(loadedCh.rateHz, for: index)
        audioEngine.setChorusDepth(loadedCh.depth, for: index)
        audioEngine.setChorusWidth(loadedCh.width, for: index)
        audioEngine.setChorusMix(loadedCh.mix, for: index)
        audioEngine.setReverbDecay(v.reverb.decaySec, for: index)
        audioEngine.setReverbMix(v.reverb.mix, for: index)
        audioEngine.setDelayTime(v.delay.timeSec, for: index)
        audioEngine.setDelayFeedback(v.delay.feedback, for: index)
        audioEngine.setDelayMix(v.delay.mix, for: index)
        for (i, lfo) in v.lfos.enumerated() {
            audioEngine.setLfoShape(lfo.shape, for: index, lfoIndex: i)
            audioEngine.setLfoTarget(lfo.target, for: index, lfoIndex: i)
            audioEngine.setLfoRate(lfo.rateHz, for: index, lfoIndex: i)
            audioEngine.setLfoDepth(lfo.depth, for: index, lfoIndex: i)
        }
        // Drift may have flipped from static to active.
        reconcileDriftRunning(snapshotIfStarting: true)
        driftSceneId = sceneIdMatchingVoices()
        activePresetName = nil
    }

    func deleteVoicePreset(_ presetId: String) {
        voicePresets.removeAll { $0.id == presetId }
        VoicePresetStore.save(voicePresets)
    }

    // MARK: - Meditation journeys

    /// Start a scripted journey. Sets the session duration to the journey
    /// total so the existing auto-stop fade kicks in at the end, then
    /// applies stage 0 immediately and schedules subsequent stages.
    func startJourney(_ id: String) {
        guard let j = Journey.all.first(where: { $0.id == id }) else { return }
        // Cancel any previous journey *without* fully stopping the transport.
        // The full stop() schedules an 8-second master fadeOut + engine.stop()
        // task; if we then immediately call play() (which fades back IN over
        // 3 s), the orphan fadeOut Task wakes up ~8 s later and calls
        // engine.stop(), cutting audio after about 6 seconds of play. So:
        // just kill the scheduler and reset journey state — don't touch the
        // transport here.
        journeyTimer?.invalidate()
        journeyTimer = nil
        journeyStageEndsAt = nil
        activeJourneyId = id
        journeyStageIndex = -1
        controller.sessionDuration = j.totalSeconds
        if controller.state != .playing { controller.play() }
        advanceJourneyStage()
    }

    func stopJourney() {
        journeyTimer?.invalidate()
        journeyTimer = nil
        activeJourneyId = nil
        journeyStageIndex = 0
        journeyStageEndsAt = nil
        // The journey IS the user's playback context — stopping it should
        // fade audio out too, otherwise tapping Stop gives no audible
        // feedback. The state.stopped Combine sink calls stopJourney back,
        // but the activeJourneyId guard above prevents infinite recursion.
        if controller.state != .stopped { controller.stop() }
    }

    private func advanceJourneyStage() {
        guard let j = activeJourney else { return }
        journeyStageIndex += 1
        if journeyStageIndex >= j.stages.count {
            // Journey complete — leave transport, the session-auto-stop
            // fade-out handles the final silence.
            activeJourneyId = nil
            return
        }
        let stage = j.stages[journeyStageIndex]
        if let preset = Preset.all.first(where: { $0.name == stage.presetName }) {
            applyPreset(preset)
        }
        setDriftScene(stage.driftSceneId)
        journeyStageEndsAt = Date().addingTimeInterval(stage.durationSec)
        journeyTimer?.invalidate()
        journeyTimer = Timer.scheduledTimer(withTimeInterval: stage.durationSec, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.advanceJourneyStage() }
        }
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
            audioEngine.setFMSource(osc.fm.sourceIndex, for: osc.id)
            audioEngine.setFMIndex(osc.fm.index, for: osc.id)
            audioEngine.setChorusRate(osc.chorus.rateHz, for: osc.id)
            audioEngine.setChorusDepth(osc.chorus.depth, for: osc.id)
            audioEngine.setChorusWidth(osc.chorus.width, for: osc.id)
            audioEngine.setChorusMix(osc.chorus.mix, for: osc.id)
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

        // Chorus — 40% chance off, otherwise musical defaults.
        if Double.random(in: 0...1) < 0.4 {
            setChorusMix(0, for: index)
        } else {
            setChorusRate(Double.random(in: 0.2...2.5), for: index)
            setChorusDepth(Double.random(in: 0.2...0.7), for: index)
            setChorusWidth(Double.random(in: 0.4...1.0), for: index)
            setChorusMix(Double.random(in: 0.15...0.55), for: index)
        }

        // FM — 50% off, otherwise pick one of the other 3 with a modest index.
        if Double.random(in: 0...1) < 0.5 {
            setFMSource(-1, for: index)
            setFMIndex(0, for: index)
        } else {
            let others = (0..<4).filter { $0 != index }
            setFMSource(others.randomElement()!, for: index)
            let bell = Double.random(in: 0...1) < 0.8
            setFMIndex(bell ? Double.random(in: 5...80) : Double.random(in: 150...400),
                       for: index)
        }

        // LFOs — random shape + target, slow rate, modest depth.
        let shapes: [LfoState.Shape] = [.sine, .triangle, .square, .sampleAndHold]
        let targets: [LfoState.Target] = [.pan, .amplitude, .cutoff, .pitch]
        for lfo in 0..<oscillators[index].lfos.count {
            setLfoShape(shapes.randomElement()!, for: index, lfoIndex: lfo)
            setLfoTarget(targets.randomElement()!, for: index, lfoIndex: lfo)
            setLfoRate(Double.random(in: 0.05...1.5), for: index, lfoIndex: lfo)
            setLfoDepth(Double.random(in: 0...0.6), for: index, lfoIndex: lfo)
        }

        // Drift — random pitch + pan motion. "static" twice-weighted in
        // each table so ~30% of voices in a roll come out quiet rather
        // than every voice flailing.
        let pitchPool: [DriftVoiceConfig.PitchMode] =
            [.static, .static, .up, .down, .upDown, .downUp, .wave, .glacial]
        let panPool: [DriftVoiceConfig.PanMode] =
            [.static, .static, .sweepLR, .sweepRL, .pendulum, .antiPendulum, .glacial]
        oscillators[index].drift.pitchAmount = Double.random(in: 0.25...1.5)
        oscillators[index].drift.pitchPhase  = Double.random(in: 0...1)
        oscillators[index].drift.panAmount   = Double.random(in: 0.5...1.0)
        oscillators[index].drift.panPhase    = Double.random(in: 0...1)
        setVoicePitchDrift(index, mode: pitchPool.randomElement()!)
        setVoicePanDrift(index, mode: panPool.randomElement()!)

        // We've drifted away from any preset.
        activePresetName = nil
    }

    // MARK: - Drift scenes
    //
    // Each scene assigns a per-voice pitch + pan motion profile. Baselines
    // are snapshotted at scene-set time; progress = elapsed / sessionDuration
    // (15 min fallback for Open sessions). Glacial-mode voices use random
    // walks; deterministic modes use phase-shifted progress through their
    // shape function (up/down/upDown/downUp/wave for pitch, sweep/pendulum
    // for pan).

    private struct DriftVoice {
        var baseFreq: Double, basePan: Double, baseAmp: Double
        var freqTarget: Double, panTarget: Double, ampTarget: Double
        var nextRetargetAt: Date
    }
    private var driftVoices: [DriftVoice] = []
    private var driftTimer: Timer?
    private var driftStart: Date = .distantPast

    func setDriftScene(_ sceneId: String) {
        if sceneId == "off" {
            stopDrift()
            return
        }
        guard let scene = Self.driftScenes.first(where: { $0.id == sceneId }) else { return }
        // Bulk-apply scene template into each voice's drift state.
        for i in 0..<oscillators.count where i < scene.voices.count {
            oscillators[i].drift = scene.voices[i]
        }
        driftSceneId = sceneId
        reconcileDriftRunning(snapshotIfStarting: true)
    }

    /// Change one voice's pitch drift mode without disturbing the others.
    func setVoicePitchDrift(_ index: Int, mode: DriftVoiceConfig.PitchMode) {
        guard index >= 0 && index < oscillators.count else { return }
        oscillators[index].drift.pitchMode = mode
        reconcileDriftRunning(snapshotIfStarting: true)
        driftSceneId = sceneIdMatchingVoices()
    }
    /// Change one voice's pan drift mode without disturbing the others.
    func setVoicePanDrift(_ index: Int, mode: DriftVoiceConfig.PanMode) {
        guard index >= 0 && index < oscillators.count else { return }
        oscillators[index].drift.panMode = mode
        reconcileDriftRunning(snapshotIfStarting: true)
        driftSceneId = sceneIdMatchingVoices()
    }

    private func stopDrift() {
        driftTimer?.invalidate()
        driftTimer = nil
        driftSceneId = "off"
        driftVoices.removeAll()
        for i in 0..<oscillators.count { oscillators[i].drift = .off }
    }

    /// Start the drift timer (snapshotting baselines) if any voice is
    /// drifting and it isn't running yet. Stop it if no voice is drifting.
    private func reconcileDriftRunning(snapshotIfStarting: Bool) {
        let active = oscillators.contains(where: { $0.drift.isActive })
        if active {
            if driftTimer == nil {
                if snapshotIfStarting {
                    driftVoices = oscillators.map {
                        DriftVoice(
                            baseFreq: $0.frequencyHz, basePan: $0.pan, baseAmp: $0.amplitude,
                            freqTarget: $0.frequencyHz, panTarget: $0.pan, ampTarget: $0.amplitude,
                            nextRetargetAt: .distantPast
                        )
                    }
                    driftStart = Date()
                }
                driftTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
                    Task { @MainActor in self?.driftTick() }
                }
            }
        } else {
            driftTimer?.invalidate()
            driftTimer = nil
            driftVoices.removeAll()
        }
    }

    /// Returns the scene id whose template matches the current per-voice
    /// drift state exactly, or "custom" if no scene matches. Used to keep
    /// the header pill label in sync after manual per-voice edits.
    private func sceneIdMatchingVoices() -> String {
        for scene in Self.driftScenes {
            var matches = true
            for i in 0..<oscillators.count where i < scene.voices.count {
                let s = scene.voices[i]
                let d = oscillators[i].drift
                if s.pitchMode != d.pitchMode || s.panMode != d.panMode ||
                   abs(s.pitchAmount - d.pitchAmount) > 0.001 {
                    matches = false; break
                }
            }
            if matches { return scene.id }
        }
        return "custom"
    }

    private func driftTick() {
        // No voice drifting → stop the timer cleanly.
        guard oscillators.contains(where: { $0.drift.isActive }) else {
            driftTimer?.invalidate(); driftTimer = nil; return
        }
        let sessionSec = controller.sessionDuration > 0 ? controller.sessionDuration : 15 * 60
        let rawProgress = min(1, max(0, Date().timeIntervalSince(driftStart) / sessionSec))

        for i in 0..<driftVoices.count {
            guard i < oscillators.count else { continue }
            let o = oscillators[i]
            let cfg = o.drift

            // ─── Pitch ───
            if cfg.pitchMode == .glacial {
                glacialPitchVoice(i)
            } else if cfg.pitchMode != .static {
                let p = (rawProgress + cfg.pitchPhase).truncatingRemainder(dividingBy: 1.0)
                let octaveOffset = Self.pitchShape(cfg.pitchMode, p: p) * cfg.pitchAmount
                let target = driftVoices[i].baseFreq * pow(2.0, octaveOffset)
                let newFreq = o.frequencyHz + (target - o.frequencyHz) * 0.30
                oscillators[i].frequencyHz = newFreq
                audioEngine.setFrequency(newFreq, for: i)
            }

            // ─── Pan ───
            if cfg.panMode == .glacial {
                glacialPanVoice(i)
            } else if cfg.panMode != .static {
                let p = (rawProgress + cfg.panPhase).truncatingRemainder(dividingBy: 1.0)
                let target = max(-1, min(1, Self.panShape(cfg.panMode, p: p) * cfg.panAmount))
                let newPan = o.pan + (target - o.pan) * 0.20
                oscillators[i].pan = newPan
                audioEngine.setPan(newPan, for: i)
            }
        }
    }

    private static func pitchShape(_ mode: DriftVoiceConfig.PitchMode, p: Double) -> Double {
        switch mode {
        case .up:     return  p
        case .down:   return -p
        case .upDown: return p < 0.5 ?  p * 2          :  1 - (p - 0.5) * 2
        case .downUp: return p < 0.5 ? -p * 2          : -1 + (p - 0.5) * 2
        case .wave:   return sin(p * .pi * 2)
        default:      return 0
        }
    }
    private static func panShape(_ mode: DriftVoiceConfig.PanMode, p: Double) -> Double {
        switch mode {
        case .sweepLR:      return -1 + p * 2
        case .sweepRL:      return  1 - p * 2
        case .pendulum:     return  sin(p * .pi * 4)
        case .antiPendulum: return -sin(p * .pi * 4)
        default:            return 0
        }
    }

    private func glacialPitchVoice(_ i: Int) {
        let now = Date()
        var v = driftVoices[i]
        let o = oscillators[i]
        if now >= v.nextRetargetAt {
            let cents = Double.random(in: -1...1) * 50.0
            v.freqTarget = v.baseFreq * pow(2.0, cents / 1200.0)
            v.ampTarget  = max(0.1, min(1, v.baseAmp + Double.random(in: -0.15...0.15)))
            v.nextRetargetAt = now.addingTimeInterval(30 + Double.random(in: 0...30))
        }
        let lerp = 0.05
        let newFreq = o.frequencyHz + (v.freqTarget - o.frequencyHz) * lerp
        let newAmp  = o.amplitude   + (v.ampTarget  - o.amplitude)   * lerp
        oscillators[i].frequencyHz = newFreq
        oscillators[i].amplitude = newAmp
        audioEngine.setFrequency(newFreq, for: i)
        audioEngine.setAmplitude(newAmp, for: i)
        driftVoices[i] = v
    }
    private func glacialPanVoice(_ i: Int) {
        let now = Date()
        var v = driftVoices[i]
        let o = oscillators[i]
        if now >= v.nextRetargetAt {
            v.panTarget = max(-1, min(1, v.basePan + Double.random(in: -0.4...0.4)))
        }
        let newPan = o.pan + (v.panTarget - o.pan) * 0.05
        oscillators[i].pan = newPan
        audioEngine.setPan(newPan, for: i)
        driftVoices[i] = v
    }
}
