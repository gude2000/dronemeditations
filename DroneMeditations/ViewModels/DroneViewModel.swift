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

    /// Unified Journey-or-UserJourney lookup result. We expose a tiny adapter
    /// instead of merging the two model types so each side keeps its native
    /// Codable shape. Used by advanceJourneyStage and the journey pill sync.
    struct JourneyHandle: Equatable {
        let id: String
        let name: String
        let description: String
        let stages: [Journey.Stage]
        var totalSeconds: TimeInterval { stages.reduce(0) { $0 + $1.durationSec } }
    }

    func journey(forId id: String) -> JourneyHandle? {
        if let j = Journey.all.first(where: { $0.id == id }) {
            return JourneyHandle(id: j.id, name: j.name, description: j.description, stages: j.stages)
        }
        if let u = userJourneys.first(where: { $0.id == id }) {
            let mapped = u.stages.map {
                Journey.Stage(durationSec: $0.durationSec,
                              presetName: $0.presetName,
                              driftSceneId: $0.driftSceneId,
                              hint: $0.hint)
            }
            return JourneyHandle(id: u.id, name: u.name, description: u.description, stages: mapped)
        }
        return nil
    }

    var activeJourney: JourneyHandle? {
        guard let id = activeJourneyId else { return nil }
        return journey(forId: id)
    }

    @Published var userPresets: [UserPreset] = UserPresetStore.load()
    /// Per-voice presets — capture/restore a single oscillator's full state
    /// so favorite voices can be mixed and matched across the four slots.
    @Published var voicePresets: [VoicePreset] = VoicePresetStore.load()
    /// User-composed journeys — scripted multi-stage sessions saved in
    /// UserDefaults. Same shape as built-in `Journey`; resolved alongside
    /// `Journey.all` at startJourney lookup time.
    @Published var userJourneys: [UserJourney] = UserJourneyStore.load()

    // ─── Morph between two presets ─────────────────────────────
    /// Pick a "From" preset and a "To" preset, then drag the slider to
    /// interpolate every per-voice parameter continuously between them.
    /// Lookups are by Preset.name (matches the picker UI). nil = no morph.
    @Published var morphFromName: String? = nil
    @Published var morphToName: String? = nil
    @Published var morphAmount: Double = 0

    // Auto-morph: drive `morphAmount` from 0→1 over `morphDurationSec`. When
    // ping-pong is on, it bounces back to 0 after reaching 1 and keeps going.
    // The timer keeps ticking while the sheet is dismissed so the user can
    // watch Chladni evolve through a long slow morph in performance mode.
    @Published var morphDurationSec: Double = 300   // 5 min default
    @Published var morphIsRunning: Bool = false
    @Published var morphIsPingPong: Bool = false
    /// 1 = forward (0→1), -1 = reversing (1→0). Used in ping-pong mode.
    private var morphDirection: Int = 1
    private var morphTimer: Timer?
    private var morphLastTickDate: Date?

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

    /// v1.1 multi-target: toggle membership of `target` in the LFO's
    /// target set. If the LFO was the LAST one driving that target on
    /// this voice, restore the slider's underlying value so the
    /// parameter doesn't get stuck wherever the LFO last left it.
    func toggleLfoTarget(_ target: LfoState.Target, for index: Int, lfoIndex: Int) {
        guard oscillators.indices.contains(index),
              oscillators[index].lfos.indices.contains(lfoIndex) else { return }
        var set = oscillators[index].lfos[lfoIndex].targets
        let wasOn = set.contains(target)
        if wasOn { set.remove(target) } else { set.insert(target) }
        oscillators[index].lfos[lfoIndex].targets = set
        audioEngine.setLfoTargets(set, for: index, lfoIndex: lfoIndex)
        // If we just removed the target AND no other LFO on this voice
        // is still driving it, restore the underlying slider value so
        // the parameter isn't frozen at the LFO's last output.
        if wasOn && !oscillators[index].lfos.contains(where: { $0.targets.contains(target) }) {
            restoreLfoBase(for: index, target: target)
        }
    }

    /// v1.0 compat: callers that still pass a single target are
    /// treated as "set the target SET to {target}". Used by preset
    /// load + the randomize path.
    func setLfoTarget(_ target: LfoState.Target, for index: Int, lfoIndex: Int) {
        guard oscillators.indices.contains(index),
              oscillators[index].lfos.indices.contains(lfoIndex) else { return }
        oscillators[index].lfos[lfoIndex].targets = [target]
        audioEngine.setLfoTargets([target], for: index, lfoIndex: lfoIndex)
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

    func setDrive(_ d: Double, for index: Int) {
        guard oscillators.indices.contains(index) else { return }
        let clamped = max(1.0, min(12.0, d))
        oscillators[index].drive = clamped
        audioEngine.setDrive(clamped, for: index)
    }

    // Granular synth setters — only audible when waveform is .granular.
    func setGrainSize(_ ms: Double, for index: Int) {
        guard oscillators.indices.contains(index) else { return }
        let clamped = max(GrainState.sizeMinMs, min(GrainState.sizeMaxMs, ms))
        oscillators[index].grain.sizeMs = clamped
        audioEngine.setGrainSize(clamped, for: index)
    }
    func setGrainDensity(_ hz: Double, for index: Int) {
        guard oscillators.indices.contains(index) else { return }
        let clamped = max(GrainState.densityMin, min(GrainState.densityMax, hz))
        oscillators[index].grain.densityHz = clamped
        audioEngine.setGrainDensity(clamped, for: index)
    }
    func setGrainJitter(_ j: Double, for index: Int) {
        guard oscillators.indices.contains(index) else { return }
        let clamped = max(0, min(1, j))
        oscillators[index].grain.jitter = clamped
        audioEngine.setGrainJitter(clamped, for: index)
    }
    func setGrainPanSpread(_ s: Double, for index: Int) {
        guard oscillators.indices.contains(index) else { return }
        let clamped = max(0, min(1, s))
        oscillators[index].grain.panSpread = clamped
        audioEngine.setGrainPanSpread(clamped, for: index)
    }

    // Per-voice sample play-window setters. Audible only when the voice's
    // waveform is .sample. (start, end) is a 0..1 fraction of the loaded
    // sample's length; fades are in seconds applied at the loop boundary.
    func setSampleStart(_ frac: Double, for index: Int) {
        guard oscillators.indices.contains(index) else { return }
        let clamped = max(0, min(0.999, frac))
        oscillators[index].sampleStartFrac = clamped
        audioEngine.setSampleStart(clamped, for: index)
    }
    func setSampleEnd(_ frac: Double, for index: Int) {
        guard oscillators.indices.contains(index) else { return }
        let clamped = max(0.001, min(1, frac))
        oscillators[index].sampleEndFrac = clamped
        audioEngine.setSampleEnd(clamped, for: index)
    }
    func setSampleFadeIn(_ sec: Double, for index: Int) {
        guard oscillators.indices.contains(index) else { return }
        let clamped = max(0, min(10, sec))
        oscillators[index].sampleFadeInSec = clamped
        audioEngine.setSampleFadeIn(clamped, for: index)
    }
    func setSampleFadeOut(_ sec: Double, for index: Int) {
        guard oscillators.indices.contains(index) else { return }
        let clamped = max(0, min(10, sec))
        oscillators[index].sampleFadeOutSec = clamped
        audioEngine.setSampleFadeOut(clamped, for: index)
    }

    // Per-voice timing envelope. 0 = play immediately / forever.
    func setStartDelay(_ sec: Double, for index: Int) {
        guard oscillators.indices.contains(index) else { return }
        let clamped = max(0, min(3600, sec))
        oscillators[index].startDelaySec = clamped
        audioEngine.setStartDelay(clamped, for: index)
    }
    func setPlayDuration(_ sec: Double, for index: Int) {
        guard oscillators.indices.contains(index) else { return }
        let clamped = max(0, min(3600, sec))
        oscillators[index].playDurationSec = clamped
        audioEngine.setPlayDuration(clamped, for: index)
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

    /// Load a sample from a bundled-in-the-app file URL (resolved by
    /// BundledSampleStore). Routes through the existing loadSample so
    /// it goes through the same persist-to-Documents path and will
    /// round-trip in user-preset saves.
    func loadBundledSample(_ entry: BundledSampleStore.Entry, for index: Int) {
        do { try loadSample(from: entry.url, for: index) }
        catch { print("[bundled] couldn't load \(entry.name): \(error)") }
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
                fm: o.fm, chorus: o.chorus, drive: o.drive,
                startDelaySec: o.startDelaySec, playDurationSec: o.playDurationSec,
                grain: o.grain
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
            // FM + Chorus + Drive (optional in preset for backward compat).
            let fm = v.fm ?? .defaults()
            let ch = v.chorus ?? .defaults()
            setDrive(v.drive ?? 1.0, for: i)
            setStartDelay(v.startDelaySec ?? 0, for: i)
            setPlayDuration(v.playDurationSec ?? 0, for: i)
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
                loadedLfos.append(LfoState(shape: .sine, targets: [.pitch], rateHz: 0.30, depth: 0))
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
        case .filterQ:   audioEngine.setFilterQ(o.filter.q, for: index)
        case .fmIndex:   audioEngine.setFMIndex(o.fm.index, for: index)
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

    /// Set both key + octave in a single applyCurrentChord pass. Used
    /// by Tune to Room's "Set as Root" — calling setKey then setOctave
    /// separately fired applyCurrentChord twice, each triggering 4
    /// frequency publishes + a quantize-scale recompute + SwiftUI
    /// re-render of every voice strip. The doubled work made the Play
    /// button unresponsive for ~1 s on the main UI right after dismiss
    /// while SwiftUI processed the change burst.
    func setKeyAndOctave(_ key: PitchClass, octave: Int) {
        currentKey = key
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
        // Recompute the quantize-to-scale cache so any voice with that
        // drift option enabled now snaps to the new chord's notes.
        recomputeQuantizeScale()
    }

    /// Cache of chord-note frequencies spanning 4 octaves centered on
    /// the chord root (1 octave below + chord + 2 octaves above), used
    /// by any voice with `drift.quantizeToScale` on. Pushed into each
    /// voice's DSP cache via Voice.scaleNotesHz. The wide span matters
    /// because the pitch LFO can swing ±1 octave at full depth when
    /// quantize is on, so a high voice swinging down must still find
    /// chord notes to snap to.
    private func recomputeQuantizeScale() {
        let rootHz = Pitch(currentKey, octave: currentOctave).frequencyEqual12()
        let chordNotes = currentChord.frequencies(rootHz: rootHz, tuning: currentTuning)
        // For each chord tone, add that tone -1, 0, +1, +2 octaves.
        // De-dup via Set (root is often already an octave duplicate).
        var unique: Set<Double> = []
        for n in chordNotes where n > 0 {
            unique.insert(n / 2)   // -1 oct
            unique.insert(n)       // root
            unique.insert(n * 2)   // +1 oct
            unique.insert(n * 4)   // +2 oct
        }
        let sorted = Array(unique).sorted()
        for i in 0..<audioEngine.voices.count {
            audioEngine.voices[i].scaleNotesHz = sorted
        }
    }

    /// Per-voice toggle for quantize-to-scale. Mirrors the flag in
    /// oscillators[i].drift to the Voice's DSP flag.
    func setVoiceQuantizeToScale(_ on: Bool, for index: Int) {
        guard oscillators.indices.contains(index),
              audioEngine.voices.indices.contains(index) else { return }
        oscillators[index].drift.quantizeToScale = on
        audioEngine.voices[index].pitchQuantizeToScale = on
        if on { recomputeQuantizeScale() }
        objectWillChange.send()
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

            // ─── Optional rich-voice fields (Drone Artists presets) ───
            // Each block is no-op when the preset's voice didn't specify it,
            // so simple presets (just hz + pan) keep their old behavior of
            // leaving the user's per-voice tone untouched.
            if let w = voice.wave {
                oscillators[i].waveform = w
                audioEngine.setWaveform(w, for: i)
            }
            if let a = voice.amp {
                oscillators[i].amplitude = a
                audioEngine.setAmplitude(a, for: i)
            }
            if let f = voice.filter {
                oscillators[i].filter = f
                audioEngine.setFilterType(f.type, for: i)
                audioEngine.setFilterCutoff(f.cutoffHz, for: i)
                audioEngine.setFilterQ(f.q, for: i)
            }
            if let dr = voice.drive {
                oscillators[i].drive = dr
                audioEngine.setDrive(dr, for: i)
            }
            // Per-voice timing envelope — only push if specified, so
            // simple presets keep their always-on behavior.
            let sdSec = voice.startDelaySec ?? 0
            let pdSec = voice.playDurationSec ?? 0
            oscillators[i].startDelaySec = sdSec
            oscillators[i].playDurationSec = pdSec
            audioEngine.setStartDelay(sdSec, for: i)
            audioEngine.setPlayDuration(pdSec, for: i)
            if let r = voice.reverb {
                oscillators[i].reverb = r
                audioEngine.setReverbDecay(r.decaySec, for: i)
                audioEngine.setReverbMix(r.mix, for: i)
            }
            if let d = voice.delay {
                oscillators[i].delay = d
                audioEngine.setDelayTime(d.timeSec, for: i)
                audioEngine.setDelayFeedback(d.feedback, for: i)
                audioEngine.setDelayMix(d.mix, for: i)
                audioEngine.setDelayMode(d.mode, for: i)
            }
            if let ch = voice.chorus {
                oscillators[i].chorus = ch
                audioEngine.setChorusRate(ch.rateHz, for: i)
                audioEngine.setChorusDepth(ch.depth, for: i)
                audioEngine.setChorusWidth(ch.width, for: i)
                audioEngine.setChorusMix(ch.mix, for: i)
            }
            if let fm = voice.fm {
                oscillators[i].fm = fm
                audioEngine.setFMSource(fm.sourceIndex, for: i)
                audioEngine.setFMIndex(fm.index, for: i)
            }
            if let gr = voice.grain {
                oscillators[i].grain = gr
                audioEngine.setGrainSize(gr.sizeMs, for: i)
                audioEngine.setGrainDensity(gr.densityHz, for: i)
                audioEngine.setGrainJitter(gr.jitter, for: i)
                audioEngine.setGrainPanSpread(gr.panSpread, for: i)
            }
            if let lfos = voice.lfos {
                // nil entries leave that LFO alone; non-nil overwrite.
                for k in 0..<min(lfos.count, 4) {
                    guard let lfo = lfos[k] else { continue }
                    oscillators[i].lfos[k] = lfo
                    audioEngine.setLfoShape(lfo.shape, for: i, lfoIndex: k)
                    audioEngine.setLfoTarget(lfo.target, for: i, lfoIndex: k)
                    audioEngine.setLfoRate(lfo.rateHz, for: i, lfoIndex: k)
                    audioEngine.setLfoDepth(lfo.depth, for: i, lfoIndex: k)
                }
            }
            if var dr = voice.drift {
                // Preserve the user's per-voice quantize-to-scale toggle
                // across preset loads — quantize is a "post-process"
                // choice that's orthogonal to the drift motion the
                // preset is specifying. Preset can still explicitly
                // turn it on (set quantizeToScale = true in the preset).
                let existingQuantize = oscillators[i].drift.quantizeToScale
                if !dr.quantizeToScale {
                    dr.quantizeToScale = existingQuantize
                }
                oscillators[i].drift = dr
                // Mirror to the DSP-side flag in the engine.
                if audioEngine.voices.indices.contains(i) {
                    audioEngine.voices[i].pitchQuantizeToScale = dr.quantizeToScale
                }
                // Push through the public setters so the drift timer reconciles.
                setVoicePitchDrift(i, mode: dr.pitchMode)
                setVoicePanDrift(i, mode: dr.panMode)
            }
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
            chorus: o.chorus,
            drive: o.drive,
            startDelaySec: o.startDelaySec,
            playDurationSec: o.playDurationSec,
            grain: o.grain
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
        let loadedDrive = v.drive ?? 1.0
        let loadedStart = v.startDelaySec ?? 0
        let loadedPlay  = v.playDurationSec ?? 0
        let loadedGrain = v.grain ?? .defaults()
        oscillators[index].fm = loadedFm
        oscillators[index].chorus = loadedCh
        oscillators[index].drive = loadedDrive
        oscillators[index].startDelaySec = loadedStart
        oscillators[index].playDurationSec = loadedPlay
        oscillators[index].grain = loadedGrain
        // Push to engine.
        audioEngine.setFrequency(v.frequencyHz, for: index)
        audioEngine.setWaveform(v.waveform, for: index)
        audioEngine.setAmplitude(v.amplitude, for: index)
        audioEngine.setPan(v.pan, for: index)
        audioEngine.setFilterType(v.filter.type, for: index)
        audioEngine.setFilterCutoff(v.filter.cutoffHz, for: index)
        audioEngine.setFilterQ(v.filter.q, for: index)
        audioEngine.setDrive(loadedDrive, for: index)
        audioEngine.setStartDelay(loadedStart, for: index)
        audioEngine.setPlayDuration(loadedPlay, for: index)
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
        audioEngine.setGrainSize(loadedGrain.sizeMs, for: index)
        audioEngine.setGrainDensity(loadedGrain.densityHz, for: index)
        audioEngine.setGrainJitter(loadedGrain.jitter, for: index)
        audioEngine.setGrainPanSpread(loadedGrain.panSpread, for: index)
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
        guard let j = journey(forId: id) else { return }
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

    // MARK: - User journeys (composer)

    /// Save a user-composed journey. `existingId` (if non-nil) is removed
    /// first so an edit replaces the original. Returns true on success.
    @discardableResult
    func saveUserJourney(name: String,
                         description: String,
                         stages: [UserJourney.Stage],
                         existingId: String? = nil) -> Bool {
        let cleanName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanName.isEmpty else { return false }
        // Filter stages defensively — durations must be 30 s ≤ d ≤ 90 min,
        // and the preset must still exist.
        let validStages = stages.compactMap { s -> UserJourney.Stage? in
            let dur = max(30, min(90 * 60, s.durationSec))
            guard Preset.all.first(where: { $0.name == s.presetName }) != nil else { return nil }
            return UserJourney.Stage(durationSec: dur,
                                     presetName: s.presetName,
                                     driftSceneId: s.driftSceneId,
                                     hint: s.hint.isEmpty ? "\(s.presetName) · \(s.driftSceneId)" : s.hint)
        }
        guard !validStages.isEmpty else { return false }
        if let existingId {
            userJourneys.removeAll { $0.id == existingId }
        }
        let entry = UserJourney(
            id: UserJourney.newId(),
            name: String(cleanName.prefix(60)),
            description: String(description.trimmingCharacters(in: .whitespacesAndNewlines).prefix(200)),
            createdAt: Date(),
            stages: validStages
        )
        userJourneys.insert(entry, at: 0)
        UserJourneyStore.save(userJourneys)
        return true
    }

    func deleteUserJourney(_ id: String) {
        userJourneys.removeAll { $0.id == id }
        UserJourneyStore.save(userJourneys)
        if activeJourneyId == id { stopJourney() }
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

    // MARK: - Morph

    func setMorphFrom(_ name: String?) {
        morphFromName = name?.isEmpty == false ? name : nil
        if morphFromName != nil, morphToName != nil { applyMorph(morphAmount) }
    }
    func setMorphTo(_ name: String?) {
        morphToName = name?.isEmpty == false ? name : nil
        if morphFromName != nil, morphToName != nil { applyMorph(morphAmount) }
    }
    func setMorphAmount(_ t: Double) {
        morphAmount = max(0, min(1, t))
        if morphFromName != nil, morphToName != nil { applyMorph(morphAmount) }
    }
    func clearMorph() {
        stopMorphTimer()
        morphFromName = nil
        morphToName = nil
        morphAmount = 0
        morphIsRunning = false
        morphDirection = 1
    }

    // MARK: - Auto-morph

    /// Pick a duration for the auto-morph (seconds). Doesn't start the timer;
    /// call `startMorph()` afterward. 0 is treated as 60 s (minimum).
    func setMorphDuration(_ sec: Double) {
        morphDurationSec = max(1, sec)
    }

    /// Toggle ping-pong (bounce back-and-forth once the morph hits an end).
    /// When off, the timer stops on reaching 1 (or 0 if reversing).
    func setMorphPingPong(_ on: Bool) {
        morphIsPingPong = on
    }

    /// Start (or resume) the auto-morph timer. No-op if From/To aren't both
    /// picked. If `morphAmount` is already at the end-of-travel for the
    /// current direction, restart from the opposite end.
    func startMorph() {
        guard morphFromName != nil, morphToName != nil else { return }
        if morphDirection == 1 && morphAmount >= 1.0 - 1e-6 {
            // Forward starting at the top: reset to 0 and go forward.
            morphAmount = 0
        } else if morphDirection == -1 && morphAmount <= 1e-6 {
            // Reverse starting at the bottom: flip to forward.
            morphDirection = 1
        }
        morphIsRunning = true
        morphLastTickDate = Date()
        morphTimer?.invalidate()
        // 10 Hz tick — plenty smooth for parameter slewing (every slider also
        // smooths to its own time constant on the engine side).
        morphTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tickMorph() }
        }
    }

    /// Pause the auto-morph at its current position; resume with `startMorph()`.
    func pauseMorph() {
        morphIsRunning = false
        stopMorphTimer()
    }

    /// Snap back to amount=0 and stop. Keeps the From/To selection intact.
    func resetMorphPosition() {
        stopMorphTimer()
        morphIsRunning = false
        morphDirection = 1
        morphAmount = 0
        if morphFromName != nil, morphToName != nil { applyMorph(0) }
    }

    private func stopMorphTimer() {
        morphTimer?.invalidate()
        morphTimer = nil
        morphLastTickDate = nil
    }

    private func tickMorph() {
        guard morphIsRunning else { return }
        let now = Date()
        let dt = now.timeIntervalSince(morphLastTickDate ?? now)
        morphLastTickDate = now
        let step = dt / max(1, morphDurationSec)
        var next = morphAmount + Double(morphDirection) * step
        if next >= 1.0 {
            if morphIsPingPong {
                next = 1.0
                morphDirection = -1
            } else {
                next = 1.0
                pauseMorph()
            }
        } else if next <= 0.0 {
            if morphIsPingPong {
                next = 0.0
                morphDirection = 1
            } else {
                next = 0.0
                pauseMorph()
            }
        }
        morphAmount = next
        applyMorph(next)
    }

    /// Look up morph voices by preset name. Checks built-in presets first,
    /// then user-saved ones. User presets get adapter-converted into
    /// Preset.Voice so the existing morph interpolation code works
    /// unchanged. Returns nil if name doesn't match any source.
    private func morphVoicesFor(name: String) -> [Preset.Voice]? {
        if let p = Preset.all.first(where: { $0.name == name }) {
            return p.voices
        }
        guard let u = userPresets.first(where: { $0.name == name }) else { return nil }
        return u.oscillators.map { v in
            Preset.Voice(
                hz: v.frequencyHz, pan: v.pan,
                wave: v.waveform, amp: v.amplitude,
                drive: v.drive,
                startDelaySec: v.startDelaySec,
                playDurationSec: v.playDurationSec,
                filter: v.filter, reverb: v.reverb,
                delay: v.delay, chorus: v.chorus,
                fm: v.fm, grain: v.grain,
                lfos: v.lfos.map(Optional.some),
                drift: nil   // user presets don't capture drift in the snapshot
            )
        }
    }

    /// Interpolate every per-voice parameter between morphFromName and
    /// morphToName at amount `t` ∈ [0, 1] and apply to the engine. Same
    /// interpolation rules as the web version (log on hz / cutoff / decay /
    /// time / rate, linear on mix / depth / pan / drive, discrete swap at
    /// the midpoint for waveform / filter type / delay mode / FM source /
    /// LFO shape + target).
    private func applyMorph(_ t: Double) {
        guard
            let aName = morphFromName,
            let bName = morphToName,
            let aVoices = morphVoicesFor(name: aName),
            let bVoices = morphVoicesFor(name: bName)
        else { return }
        // Wrap into a minimal Preset-like shape so the existing morph body
        // (which reads `.voices` and `.name`) keeps working untouched.
        let A = (name: aName, voices: aVoices)
        let B = (name: bName, voices: bVoices)
        let u = max(0, min(1, t))
        func lerp(_ a: Double, _ b: Double) -> Double { a + (b - a) * u }
        func logLerp(_ a: Double, _ b: Double) -> Double {
            (a > 0 && b > 0) ? exp(lerp(log(a), log(b))) : lerp(a, b)
        }
        func pick<T>(_ a: T, _ b: T) -> T { u < 0.5 ? a : b }

        // Crossfade-through-zero around the discrete-swap point (u = 0.5).
        // Voices whose waveform / filter type / FM source differs between A
        // and B briefly fade to silence at u ≈ 0.5 so the abrupt timbre
        // swap is inaudible. Window is ~8 s wide, expressed in morph-amount
        // units. Clamped so it can never consume more than the middle ±45 %
        // of the morph (avoids weird behavior at short durations).
        let fadeWindowSec = 8.0
        let halfWidth = min(0.45, fadeWindowSec / max(8.0, morphDurationSec) / 2.0)
        let dist = abs(u - 0.5)
        let notchMul: Double
        if dist >= halfWidth || halfWidth <= 0 {
            notchMul = 1.0
        } else {
            // Cos-shaped notch: 1 at edges, 0 at center.
            notchMul = 0.5 - 0.5 * cos(.pi * dist / halfWidth)
        }

        for i in 0..<4 {
            guard i < A.voices.count, i < B.voices.count else { continue }
            let va = A.voices[i]
            let vb = B.voices[i]
            let o = oscillators[i]

            let aHz   = va.hz, bHz = vb.hz
            let aPan  = va.pan, bPan = vb.pan
            let aWave = va.wave ?? o.waveform
            let bWave = vb.wave ?? o.waveform
            let aAmp  = va.amp ?? o.amplitude
            let bAmp  = vb.amp ?? o.amplitude
            let aDrv  = va.drive ?? o.drive
            let bDrv  = vb.drive ?? o.drive

            // Per-voice notch — only applies if this voice has a discrete
            // change. Voices that only differ in continuous params (freq,
            // amp, filter cutoff) stay at their lerped amplitude.
            let aFmSrc = (va.fm ?? .defaults()).sourceIndex
            let bFmSrc = (vb.fm ?? .defaults()).sourceIndex
            let aFilterType = (va.filter ?? o.filter).type
            let bFilterType = (vb.filter ?? o.filter).type
            let hasDiscreteChange = (aWave != bWave)
                || (aFilterType != bFilterType)
                || (aFmSrc != bFmSrc)
            let voiceAmpMul = hasDiscreteChange ? notchMul : 1.0

            setFrequency(logLerp(aHz, bHz), for: i)
            setPan(lerp(aPan, bPan), for: i)
            setAmplitude(lerp(aAmp, bAmp) * voiceAmpMul, for: i)
            setDrive(lerp(aDrv, bDrv), for: i)
            let wantWave = pick(aWave, bWave)
            if o.waveform != wantWave { setWaveform(wantWave, for: i) }

            // Filter
            let aF = va.filter ?? o.filter
            let bF = vb.filter ?? o.filter
            let wantType = pick(aF.type, bF.type)
            if o.filter.type != wantType { setFilterType(wantType, for: i) }
            setFilterCutoff(logLerp(aF.cutoffHz, bF.cutoffHz), for: i)
            setFilterQ(logLerp(aF.q, bF.q), for: i)

            // Reverb
            let aR = va.reverb ?? o.reverb
            let bR = vb.reverb ?? o.reverb
            setReverbDecay(logLerp(aR.decaySec, bR.decaySec), for: i)
            setReverbMix(lerp(aR.mix, bR.mix), for: i)

            // Delay
            let aD = va.delay ?? o.delay
            let bD = vb.delay ?? o.delay
            setDelayTime(logLerp(aD.timeSec, bD.timeSec), for: i)
            setDelayFeedback(lerp(aD.feedback, bD.feedback), for: i)
            setDelayMix(lerp(aD.mix, bD.mix), for: i)
            let wantDly = pick(aD.mode, bD.mode)
            if o.delay.mode != wantDly { setDelayMode(wantDly, for: i) }

            // Chorus
            let aC = va.chorus ?? o.chorus
            let bC = vb.chorus ?? o.chorus
            setChorusRate(logLerp(aC.rateHz, bC.rateHz), for: i)
            setChorusDepth(lerp(aC.depth, bC.depth), for: i)
            setChorusWidth(lerp(aC.width, bC.width), for: i)
            setChorusMix(lerp(aC.mix, bC.mix), for: i)

            // FM
            let aFm = va.fm ?? o.fm
            let bFm = vb.fm ?? o.fm
            let wantFmSrc = pick(aFm.sourceIndex, bFm.sourceIndex)
            if o.fm.sourceIndex != wantFmSrc { setFMSource(wantFmSrc, for: i) }
            let idx = (aFm.index > 1 && bFm.index > 1) ? logLerp(aFm.index, bFm.index) : lerp(aFm.index, bFm.index)
            setFMIndex(idx, for: i)

            // Granular (only audible while wave is .granular). Size + density
            // morph log so they stay musical across the range; jitter + pan
            // spread morph linearly.
            let aG = va.grain ?? o.grain
            let bG = vb.grain ?? o.grain
            setGrainSize(logLerp(aG.sizeMs, bG.sizeMs), for: i)
            setGrainDensity(logLerp(aG.densityHz, bG.densityHz), for: i)
            setGrainJitter(lerp(aG.jitter, bG.jitter), for: i)
            setGrainPanSpread(lerp(aG.panSpread, bG.panSpread), for: i)

            // LFOs — interpolate rate (log) + depth (linear); discrete
            // shape + target swap at midpoint.
            let aLfos = va.lfos ?? []
            let bLfos = vb.lfos ?? []
            for k in 0..<4 where k < o.lfos.count {
                let al = (k < aLfos.count ? aLfos[k] : nil) ?? o.lfos[k]
                let bl = (k < bLfos.count ? bLfos[k] : nil) ?? o.lfos[k]
                setLfoRate(logLerp(al.rateHz, bl.rateHz), for: i, lfoIndex: k)
                setLfoDepth(lerp(al.depth, bl.depth), for: i, lfoIndex: k)
                let wantShape = pick(al.shape, bl.shape)
                if o.lfos[k].shape != wantShape { setLfoShape(wantShape, for: i, lfoIndex: k) }
                let wantTarget = pick(al.target, bl.target)
                if o.lfos[k].target != wantTarget { setLfoTarget(wantTarget, for: i, lfoIndex: k) }
            }
        }
        activePresetName = "\(A.name) → \(B.name) (\(Int(u * 100))%)"
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
            audioEngine.setDrive(osc.drive, for: osc.id)
            audioEngine.setStartDelay(osc.startDelaySec, for: osc.id)
            audioEngine.setPlayDuration(osc.playDurationSec, for: osc.id)
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

    /// Randomize the WHOLE preset — all 4 voices' parameters plus a
    /// random chord (root + type) so the result really sounds different,
    /// not just "same chord, different timbres." Volume levels are
    /// deliberately preserved so the user doesn't get blasted or muted
    /// by a roll. Wired to the dice button next to the OSC nav pills.
    func randomizeAll() {
        // Pick a random chord first so randomizeOscillator's frequency
        // re-rolls below aren't immediately stomped by applyCurrentChord.
        // Actually we WANT them stomped — chord drives the four voice
        // frequencies, while randomizeOscillator(i) picks a random
        // standalone frequency. Order matters: apply chord LAST so the
        // chord wins. Otherwise per-voice random frequencies overwrite
        // the chord notes.
        let randomKey = PitchClass.allCases.randomElement() ?? .a
        let randomOctave = Int.random(in: 2...4)
        // Pick a chord from the "Common" + "Extended" categories — skip
        // exotic ones (clusters / quartal) that don't always sound
        // pleasant cold.
        let chordCandidates = ChordType.all.filter { ct in
            let n = ct.id.lowercased()
            return !(n.contains("cluster") || n.contains("quartal")
                  || n.contains("xenakis") || n.contains("scriabin")
                  || n.contains("sable"))
        }
        let randomChord = chordCandidates.randomElement() ?? ChordType.all[0]

        for i in 0..<oscillators.count {
            randomizeOscillator(i)
        }
        // setChord runs applyCurrentChord which overwrites voice
        // frequencies with chord notes — perfect, that's what we want.
        currentKey = randomKey
        currentOctave = max(0, min(7, randomOctave))
        setChord(randomChord)
        // setChord clears activePresetName via applyCurrentChord; that's
        // correct since this isn't a saved preset.
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
        // Bulk-apply scene template into each voice's drift state — but
        // preserve the per-voice quantize-to-scale toggle (independent
        // of drift motion). Scene only describes pitch/pan motion.
        for i in 0..<oscillators.count where i < scene.voices.count {
            let keepQuantize = oscillators[i].drift.quantizeToScale
            var dr = scene.voices[i]
            dr.quantizeToScale = keepQuantize
            oscillators[i].drift = dr
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

    /// Override the pitch-drift amplitude in semitones (0.1 – 24).
    /// Pass nil to revert to the mode's default amplitude (which uses
    /// the legacy `pitchAmount * 1 octave` math).
    func setVoicePitchSemitones(_ index: Int, semitones: Double?) {
        guard index >= 0 && index < oscillators.count else { return }
        if let s = semitones {
            oscillators[index].drift.pitchSemitones = max(0.1, min(24, s))
        } else {
            oscillators[index].drift.pitchSemitones = nil
        }
        reconcileDriftRunning(snapshotIfStarting: true)
        driftSceneId = sceneIdMatchingVoices()
    }

    /// Override the pitch-drift period in seconds (10 – 1200). When set,
    /// the cycle repeats every N sec using absolute time. Pass nil to
    /// revert to the default behavior where one cycle = full session.
    func setVoicePitchPeriodSec(_ index: Int, sec: Double?) {
        guard index >= 0 && index < oscillators.count else { return }
        if let s = sec {
            oscillators[index].drift.pitchPeriodSec = max(10, min(1200, s))
        } else {
            oscillators[index].drift.pitchPeriodSec = nil
        }
        reconcileDriftRunning(snapshotIfStarting: true)
        driftSceneId = sceneIdMatchingVoices()
    }

    private func stopDrift() {
        driftTimer?.invalidate()
        driftTimer = nil
        driftSceneId = "off"
        driftVoices.removeAll()
        // Reset motion to static but preserve the per-voice quantize
        // toggle — it's an independent post-process setting.
        for i in 0..<oscillators.count {
            let keepQuantize = oscillators[i].drift.quantizeToScale
            oscillators[i].drift = .off
            oscillators[i].drift.quantizeToScale = keepQuantize
        }
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
            } else if cfg.pitchMode == .ocean {
                // Ocean: subtle slow sine wave around the base pitch.
                // ±0.25 semitone over a 90 s period. User-configurable
                // overrides on the same voice take precedence if set.
                let oceanPeriod: Double = cfg.pitchPeriodSec ?? 90.0
                let amplitudeOctaves: Double
                if let semis = cfg.pitchSemitones {
                    amplitudeOctaves = semis / 12.0
                } else {
                    amplitudeOctaves = 0.25 / 12.0 * cfg.pitchAmount
                }
                let t = Date().timeIntervalSince(driftStart)
                let phase = ((t / oceanPeriod) + cfg.pitchPhase)
                    .truncatingRemainder(dividingBy: 1.0)
                let octaveOffset = sin(phase * .pi * 2) * amplitudeOctaves
                let target = driftVoices[i].baseFreq * pow(2.0, octaveOffset)
                let newFreq = o.frequencyHz + (target - o.frequencyHz) * 0.30
                oscillators[i].frequencyHz = newFreq
                audioEngine.setFrequency(newFreq, for: i)
            } else if cfg.pitchMode != .static {
                // For non-glacial / non-ocean modes: phase comes from
                // either the session-progress (default, full cycle over
                // session length) OR absolute-time / period override.
                // Amplitude comes from semitones-override if set, else
                // pitchAmount (legacy = full-octave-multiplier).
                let phase: Double
                if let period = cfg.pitchPeriodSec, period > 0 {
                    let t = Date().timeIntervalSince(driftStart)
                    phase = ((t / period) + cfg.pitchPhase)
                        .truncatingRemainder(dividingBy: 1.0)
                } else {
                    phase = (rawProgress + cfg.pitchPhase)
                        .truncatingRemainder(dividingBy: 1.0)
                }
                let amplitudeOctaves: Double
                if let semis = cfg.pitchSemitones {
                    amplitudeOctaves = semis / 12.0
                } else {
                    amplitudeOctaves = cfg.pitchAmount
                }
                let octaveOffset = Self.pitchShape(cfg.pitchMode, p: phase) * amplitudeOctaves
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
