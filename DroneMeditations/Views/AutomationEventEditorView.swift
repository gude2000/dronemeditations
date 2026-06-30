import SwiftUI

/// Sheet for editing one AutomationEvent. Opens from AutomationSheetView
/// either as "edit existing" (tap a row) or "create new" (tap +).
/// On Save, the VM upserts by id — so editing an existing event keeps
/// its id and just updates fields, while a new event gets persisted.
struct AutomationEventEditorView: View {
    @EnvironmentObject var vm: DroneViewModel
    @Environment(\.dismiss) private var dismiss

    /// Local copy of the event so cancellation discards edits.
    @State private var draft: AutomationEvent
    /// Set by the parent (AutomationSheetView) — true when the editor was
    /// opened from a row tap (existing event), false when opened from the
    /// + button (new event). Controls Delete-button visibility.
    private let isExisting: Bool

    @State private var timeMinutes: Int
    @State private var timeSeconds: Int

    // LFO rate/depth event fields live in local @State rather than packed
    // into draft.action. Why: binding the LFO-index Picker through a
    // computed binding that reassigns draft.action makes BOTH the LFO
    // picker and the Type picker (which also reads draft.action) re-render
    // on every LFO selection — janky, "finicky dropdown." Local @State
    // decouples them; we fold these back into draft.action only on Save.
    @State private var lfoIndex: Int
    @State private var lfoRate: Double
    @State private var lfoDepth: Double

    init(event: AutomationEvent, isExisting: Bool = true) {
        let totalSec = Int(event.timeSec.rounded(.down))
        _draft = State(initialValue: event)
        _timeMinutes = State(initialValue: totalSec / 60)
        _timeSeconds = State(initialValue: totalSec % 60)
        self.isExisting = isExisting
        // Seed the LFO locals from the event's action if it's an LFO type;
        // otherwise sensible defaults (LFO 4 = pitch LFO in most presets).
        switch event.action {
        case .lfoRate(let idx, let rate):
            _lfoIndex = State(initialValue: idx)
            _lfoRate = State(initialValue: rate)
            _lfoDepth = State(initialValue: 0.5)
        case .lfoDepth(let idx, let depth):
            _lfoIndex = State(initialValue: idx)
            _lfoRate = State(initialValue: 0.5)
            _lfoDepth = State(initialValue: depth)
        default:
            _lfoIndex = State(initialValue: 3)
            _lfoRate = State(initialValue: 0.5)
            _lfoDepth = State(initialValue: 0.5)
        }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Time") {
                    HStack {
                        Stepper(value: $timeMinutes, in: 0...120) {
                            Text("\(timeMinutes) min")
                                .font(.system(.body, design: .monospaced))
                        }
                    }
                    HStack {
                        Stepper(value: $timeSeconds, in: 0...59) {
                            Text("\(timeSeconds) sec")
                                .font(.system(.body, design: .monospaced))
                        }
                    }
                }
                Section("Apply to") {
                    // navigationLink picker style — selection on a pushed
                    // screen, immune to tap-region overlap and to the sheet
                    // re-rendering mid-tap when the observed vm churns
                    // @Published during playback. The Int-tag mapping
                    // (-1 = all, 0–3 = oscillator) is still needed because
                    // VoiceFilter is an enum with associated values, which
                    // SwiftUI Picker tag-matching handles unreliably.
                    Picker("Voice", selection: voiceIndexBinding) {
                        Text("All voices").tag(-1)
                        ForEach(0..<4) { i in
                            Text("OSC \(i + 1)").tag(i)
                        }
                    }
                    .pickerStyle(.navigationLink)
                }
                Section("Action") {
                    Picker("Type", selection: actionTypeBinding) {
                        Text("Chord change").tag(ActionType.chord)
                        Text("Fade in").tag(ActionType.fadeIn)
                        Text("Fade out").tag(ActionType.fadeOut)
                        Text("Waveform").tag(ActionType.waveform)
                        Text("Level").tag(ActionType.level)
                        Text("Mute toggle").tag(ActionType.muteToggle)
                        Text("LFO rate").tag(ActionType.lfoRate)
                        Text("LFO depth").tag(ActionType.lfoDepth)
                    }
                    .pickerStyle(.navigationLink)
                    actionFields
                }
                if isExisting {
                    Section {
                        Button(role: .destructive) {
                            vm.deleteAutomationEvent(draft.id)
                            dismiss()
                        } label: {
                            Label("Delete event", systemImage: "trash")
                        }
                    }
                }
            }
            .navigationTitle("Event")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        commitTime()
                        commitLfoFields()
                        vm.upsertAutomationEvent(draft)
                        dismiss()
                    }
                }
            }
        }
    }

    // MARK: - Action-specific fields

    @ViewBuilder
    private var actionFields: some View {
        switch draft.action {
        case .chordChange:
            chordFields
        case .fadeIn(let dur):
            fadeSlider(durationSec: dur, isFadeIn: true)
        case .fadeOut(let dur):
            fadeSlider(durationSec: dur, isFadeIn: false)
        case .waveformSet:
            waveformPicker
        case .levelSet:
            levelSlider
        case .muteToggle:
            Text("Inverts the mute state of the selected voice(s) when fired.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        case .lfoRate:
            lfoIndexPicker
            lfoRateSlider
        case .lfoDepth:
            lfoIndexPicker
            lfoDepthSlider
        }
    }

    // Bare Pickers — no surrounding HStack/Spacer/manual labels.
    // Form lays out a `Picker(title, selection:)` as a row with the
    // title on the left and the current value on the right, and routes
    // taps directly to the Picker's menu. Wrapping in HStack creates an
    // overlapping tap region that swallows ~half the picker taps —
    // which the user reported as "I have to click 10 times before it
    // switches options."
    @ViewBuilder
    private var chordFields: some View {
        Picker("Key", selection: keyBinding) {
            ForEach(PitchClass.allCases) { pc in
                Text(pc.displayName).tag(pc.rawValue)
            }
        }
        .pickerStyle(.navigationLink)
        Picker("Chord", selection: chordIdBinding) {
            ForEach(ChordType.Category.allCases, id: \.self) { category in
                Section(category.rawValue) {
                    ForEach(ChordType.all.filter { $0.category == category }, id: \.id) { c in
                        Text(c.name).tag(c.id)
                    }
                }
            }
        }
        .pickerStyle(.navigationLink)
    }

    private func fadeSlider(durationSec: Double, isFadeIn: Bool) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Duration")
                Spacer()
                Text(String(format: "%.1f s", durationSec))
                    .font(.system(.subheadline, design: .monospaced))
                    .foregroundStyle(Color.accentColor)
            }
            Slider(
                value: Binding(
                    get: { durationSec },
                    set: { newVal in
                        let clamped = max(0, min(15.0, newVal))
                        draft.action = isFadeIn
                            ? .fadeIn(durationSec: clamped)
                            : .fadeOut(durationSec: clamped)
                    }
                ),
                in: 0...15,
                step: 0.5
            )
        }
    }

    // MARK: - Bindings

    /// Maps `draft.voice` onto Int for SwiftUI Picker tag matching.
    /// -1 = .all; 0–3 = .oscillator(i). See picker comment above for why.
    private var voiceIndexBinding: Binding<Int> {
        Binding(
            get: {
                switch draft.voice {
                case .all: return -1
                case .oscillator(let i): return i
                }
            },
            set: { newIdx in
                if newIdx == -1 {
                    draft.voice = .all
                } else {
                    draft.voice = .oscillator(max(0, min(3, newIdx)))
                }
            }
        )
    }

    private enum ActionType: String, Hashable {
        case chord, fadeIn, fadeOut, waveform, level, muteToggle, lfoRate, lfoDepth
    }

    private var actionTypeBinding: Binding<ActionType> {
        Binding(
            get: {
                switch draft.action {
                case .chordChange: return .chord
                case .fadeIn:      return .fadeIn
                case .fadeOut:     return .fadeOut
                case .waveformSet: return .waveform
                case .levelSet:    return .level
                case .muteToggle:  return .muteToggle
                case .lfoRate:     return .lfoRate
                case .lfoDepth:    return .lfoDepth
                }
            },
            set: { newType in
                switch newType {
                case .chord:
                    draft.action = .chordChange(
                        keyRaw: vm.currentKey.rawValue,
                        chordId: vm.currentChord.id
                    )
                case .fadeIn:
                    draft.action = .fadeIn(durationSec: 3.0)
                case .fadeOut:
                    draft.action = .fadeOut(durationSec: 5.0)
                case .waveform:
                    // Default to sine — the closest analog to "no
                    // particular waveform". User overrides via the picker.
                    draft.action = .waveformSet(waveformRaw: Waveform.sine.rawValue)
                case .level:
                    draft.action = .levelSet(level: 0.5)
                case .muteToggle:
                    draft.action = .muteToggle
                case .lfoRate:
                    // Default to LFO 4 (the pitch LFO in most presets)
                    // at a slow-ish 0.5 Hz. User adjusts both via the
                    // pickers below.
                    draft.action = .lfoRate(lfoIndex: 3, rateHz: 0.5)
                case .lfoDepth:
                    draft.action = .lfoDepth(lfoIndex: 3, depth: 0.5)
                }
            }
        )
    }

    private var keyBinding: Binding<Int> {
        Binding(
            get: {
                if case .chordChange(let keyRaw, _) = draft.action {
                    return keyRaw
                }
                return PitchClass.a.rawValue
            },
            set: { newKey in
                if case .chordChange(_, let chordId) = draft.action {
                    draft.action = .chordChange(keyRaw: newKey, chordId: chordId)
                }
            }
        )
    }

    private var chordIdBinding: Binding<String> {
        Binding(
            get: {
                if case .chordChange(_, let chordId) = draft.action {
                    return chordId
                }
                return ChordType.all[0].id
            },
            set: { newId in
                if case .chordChange(let keyRaw, _) = draft.action {
                    draft.action = .chordChange(keyRaw: keyRaw, chordId: newId)
                }
            }
        )
    }

    private func commitTime() {
        draft.timeSec = Double(timeMinutes * 60 + timeSeconds)
    }

    // MARK: - Phase B fields

    @ViewBuilder
    private var waveformPicker: some View {
        Picker("Waveform", selection: waveformBinding) {
            ForEach(Waveform.allCases) { wf in
                Text(wf.displayName).tag(wf.rawValue)
            }
        }
        .pickerStyle(.navigationLink)
        // Surface a sample picker only when the chosen waveform is .sample.
        // Without one the action would set the voice to sample-mode with
        // an empty buffer (= silence). The picker lists every
        // BundledSampleStore.Entry (bundle + user Documents/User samples)
        // grouped by category.
        if currentWaveformRaw == Waveform.sample.rawValue {
            Picker("Sample", selection: sampleNameBinding) {
                Text("— Choose —").tag("")
                let groups = Dictionary(grouping: BundledSampleStore.all) { $0.category }
                ForEach(groups.keys.sorted(), id: \.self) { category in
                    Section(category) {
                        ForEach(
                            groups[category]?.sorted { $0.name.lowercased() < $1.name.lowercased() } ?? [],
                            id: \.id
                        ) { entry in
                            Text(entry.name).tag(entry.name)
                        }
                    }
                }
            }
            .pickerStyle(.navigationLink)
            if (draft.sampleName ?? "").isEmpty {
                Text("Pick a sample — the voice will load this file before the waveform flips to Sample mode at fire time.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var levelSlider: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Level")
                Spacer()
                Text("\(Int(round(currentLevel * 100)))%")
                    .font(.system(.subheadline, design: .monospaced))
                    .foregroundStyle(Color.accentColor)
            }
            Slider(
                value: Binding(
                    get: { currentLevel },
                    set: { newVal in
                        draft.action = .levelSet(level: max(0, min(1.0, newVal)))
                    }
                ),
                in: 0...1,
                step: 0.01
            )
        }
    }

    // MARK: - LFO rate / depth fields

    /// Which LFO (1–5) the rate/depth event targets. Binds to the local
    /// @State `lfoIndex` so changing it doesn't reassign draft.action and
    /// disturb the Type picker. Folded into draft.action on Save.
    private var lfoIndexPicker: some View {
        Picker("LFO", selection: $lfoIndex) {
            ForEach(0..<5) { i in
                Text("LFO \(i + 1)").tag(i)
            }
        }
        .pickerStyle(.navigationLink)
    }

    private var lfoRateSlider: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Rate")
                Spacer()
                Text(String(format: "%.3f Hz", lfoRate))
                    .font(.system(.subheadline, design: .monospaced))
                    .foregroundStyle(Color.accentColor)
            }
            // Log-spaced feel: a linear 0…1 slider mapped through the
            // LFO's rateMin…rateMax range exponentially so the slow end
            // (where S&H pitch envelopes live) has fine resolution.
            Slider(
                value: Binding(
                    get: { lfoRateToSliderPos(lfoRate) },
                    set: { pos in lfoRate = sliderPosToLfoRate(pos) }
                ),
                in: 0...1
            )
        }
    }

    private var lfoDepthSlider: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Depth")
                Spacer()
                Text("\(Int(round(lfoDepth * 100)))%")
                    .font(.system(.subheadline, design: .monospaced))
                    .foregroundStyle(Color.accentColor)
            }
            Slider(value: $lfoDepth, in: 0...1, step: 0.01)
        }
    }

    // Log mapping between a 0…1 slider position and the LFO rate range.
    private func lfoRateToSliderPos(_ hz: Double) -> Double {
        let lo = log(LfoState.rateMin)
        let hi = log(LfoState.rateMax)
        let clamped = max(LfoState.rateMin, min(LfoState.rateMax, hz))
        return (log(clamped) - lo) / (hi - lo)
    }
    private func sliderPosToLfoRate(_ pos: Double) -> Double {
        let lo = log(LfoState.rateMin)
        let hi = log(LfoState.rateMax)
        return exp(lo + (hi - lo) * max(0, min(1, pos)))
    }

    /// Fold the LFO @State locals back into draft.action on Save. No-op
    /// for non-LFO action types.
    private func commitLfoFields() {
        switch draft.action {
        case .lfoRate:
            draft.action = .lfoRate(
                lfoIndex: max(0, min(4, lfoIndex)),
                rateHz: max(LfoState.rateMin, min(LfoState.rateMax, lfoRate))
            )
        case .lfoDepth:
            draft.action = .lfoDepth(
                lfoIndex: max(0, min(4, lfoIndex)),
                depth: max(0, min(1, lfoDepth))
            )
        default:
            break
        }
    }

    private var waveformBinding: Binding<String> {
        Binding(
            get: {
                if case .waveformSet(let raw) = draft.action { return raw }
                return Waveform.sine.rawValue
            },
            set: { newRaw in
                draft.action = .waveformSet(waveformRaw: newRaw)
                // Clear stale sample selection when switching AWAY from
                // sample — keeps the model honest and avoids round-
                // tripping a sample name that's no longer relevant.
                if newRaw != Waveform.sample.rawValue {
                    draft.sampleName = nil
                }
            }
        )
    }

    /// Binding for the sample-name picker (only visible when waveform is
    /// .sample). Empty string ↔ nil so the Picker's "— Choose —" sentinel
    /// can be selected without falling out of the Hashable tag space.
    private var sampleNameBinding: Binding<String> {
        Binding(
            get: { draft.sampleName ?? "" },
            set: { draft.sampleName = $0.isEmpty ? nil : $0 }
        )
    }

    /// Convenience accessor for the conditional sample row in waveformPicker.
    private var currentWaveformRaw: String {
        if case .waveformSet(let raw) = draft.action { return raw }
        return ""
    }

    private var currentLevel: Double {
        if case .levelSet(let lvl) = draft.action { return lvl }
        return 0.5
    }
}
