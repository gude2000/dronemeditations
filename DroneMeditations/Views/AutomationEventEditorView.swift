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

    init(event: AutomationEvent, isExisting: Bool = true) {
        let totalSec = Int(event.timeSec.rounded(.down))
        _draft = State(initialValue: event)
        _timeMinutes = State(initialValue: totalSec / 60)
        _timeSeconds = State(initialValue: totalSec % 60)
        self.isExisting = isExisting
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
                    Picker("Voice", selection: voiceBinding) {
                        Text("All voices").tag(VoiceFilter.all)
                        ForEach(0..<4) { i in
                            Text("OSC \(i + 1)").tag(VoiceFilter.oscillator(i))
                        }
                    }
                    .pickerStyle(.menu)
                }
                Section("Action") {
                    Picker("Type", selection: actionTypeBinding) {
                        Text("Chord change").tag(ActionType.chord)
                        Text("Fade in").tag(ActionType.fadeIn)
                        Text("Fade out").tag(ActionType.fadeOut)
                        Text("Waveform").tag(ActionType.waveform)
                        Text("Level").tag(ActionType.level)
                        Text("Mute toggle").tag(ActionType.muteToggle)
                    }
                    .pickerStyle(.menu)
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
        }
    }

    private var chordFields: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Key").foregroundStyle(.secondary)
                Spacer()
                Picker("Key", selection: keyBinding) {
                    ForEach(PitchClass.allCases) { pc in
                        Text(pc.displayName).tag(pc.rawValue)
                    }
                }
                .pickerStyle(.menu)
            }
            HStack {
                Text("Chord").foregroundStyle(.secondary)
                Spacer()
                Picker("Chord", selection: chordIdBinding) {
                    ForEach(ChordType.Category.allCases, id: \.self) { category in
                        Section(category.rawValue) {
                            ForEach(ChordType.all.filter { $0.category == category }, id: \.id) { c in
                                Text(c.name).tag(c.id)
                            }
                        }
                    }
                }
                .pickerStyle(.menu)
            }
        }
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

    private var voiceBinding: Binding<VoiceFilter> {
        Binding(
            get: { draft.voice },
            set: { draft.voice = $0 }
        )
    }

    private enum ActionType: String, Hashable {
        case chord, fadeIn, fadeOut, waveform, level, muteToggle
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

    private var waveformPicker: some View {
        HStack {
            Text("Waveform").foregroundStyle(.secondary)
            Spacer()
            Picker("Waveform", selection: waveformBinding) {
                ForEach(Waveform.allCases) { wf in
                    Text(wf.displayName).tag(wf.rawValue)
                }
            }
            .pickerStyle(.menu)
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

    private var waveformBinding: Binding<String> {
        Binding(
            get: {
                if case .waveformSet(let raw) = draft.action { return raw }
                return Waveform.sine.rawValue
            },
            set: { newRaw in
                draft.action = .waveformSet(waveformRaw: newRaw)
            }
        )
    }

    private var currentLevel: Double {
        if case .levelSet(let lvl) = draft.action { return lvl }
        return 0.5
    }
}
