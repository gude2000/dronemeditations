import SwiftUI

/// Top-level UI for editing the AutomationTimeline. Opens from the
/// AUTOMATION pill in the controls header. Lists events in time order;
/// tapping a row opens an editor sheet for that event. Plus a Duration
/// / Loop section at the top — Duration = 0 means "until manual stop"
/// per the v1.1 locked design.
struct AutomationSheetView: View {
    @EnvironmentObject var vm: DroneViewModel
    @Environment(\.dismiss) private var dismiss

    /// Single sheet presentation source. Two stacked `.sheet` modifiers on
    /// the same view aren't reliably supported by SwiftUI — only one can
    /// be presented at a time, and re-presenting the second one after the
    /// first dismisses leaves the picker bindings in a stale state. We
    /// fold both "edit existing" and "create new" into a single
    /// `EditorTarget` and present it via `.sheet(item:)`.
    @State private var editorTarget: EditorTarget?

    private struct EditorTarget: Identifiable {
        let event: AutomationEvent
        let isExisting: Bool
        var id: UUID { event.id }
    }

    // Automation-setups library state.
    @State private var showSaveSetupAlert = false
    @State private var setupName = ""
    @State private var pendingLoad: AutomationSetup?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    lengthPicker
                    repeatPicker
                        .disabled(vm.automation.totalBars == nil)
                } header: {
                    Text("Timeline").font(.caption)
                } footer: {
                    Text(footerText).font(.caption)
                }

                Section {
                    if vm.automation.events.isEmpty {
                        Text("No events yet. Tap + to add a chord change or fade.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(vm.automation.events) { event in
                            Button {
                                editorTarget = EditorTarget(event: event, isExisting: true)
                            } label: {
                                eventRow(event)
                            }
                            .buttonStyle(.plain)
                            .swipeActions {
                                Button(role: .destructive) {
                                    vm.deleteAutomationEvent(event.id)
                                } label: {
                                    Label("Delete", systemImage: "trash")
                                }
                            }
                        }
                    }
                } header: {
                    HStack {
                        Text("Events (\(vm.automation.events.count))")
                            .font(.caption)
                        Spacer()
                        Button {
                            editorTarget = EditorTarget(
                                event: defaultNewEvent(),
                                isExisting: false
                            )
                        } label: {
                            Image(systemName: "plus.circle.fill")
                                .font(.system(size: 18))
                        }
                        .buttonStyle(.plain)
                    }
                }
                if vm.automation.events.count >= AutomationTimeline.softCapEvents {
                    Section {
                        HStack(spacing: 8) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundStyle(.orange)
                            Text("\(vm.automation.events.count) events — large timelines can be hard to edit. Hard cap \(AutomationTimeline.hardCapEvents).")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                // Reusable setups library — save the current timeline under a
                // name and load it onto any patch later.
                Section {
                    if vm.automationSetups.isEmpty {
                        Text("No saved setups. Build a timeline, then Save to reuse it on any patch.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(vm.automationSetups) { setup in
                            Button { pendingLoad = setup } label: { setupRow(setup) }
                                .buttonStyle(.plain)
                                .swipeActions {
                                    Button(role: .destructive) {
                                        vm.deleteAutomationSetup(id: setup.id)
                                    } label: {
                                        Label("Delete", systemImage: "trash")
                                    }
                                }
                        }
                    }
                } header: {
                    HStack {
                        Text("Saved setups").font(.caption)
                        Spacer()
                        Button("Save current…") {
                            setupName = ""
                            showSaveSetupAlert = true
                        }
                        .font(.caption)
                        .disabled(vm.automation.events.isEmpty)
                    }
                }
            }
            .navigationTitle("Automation")
            .navigationBarTitleDisplayMode(.inline)
            .onAppear {
                // Upgrade any legacy events to tempo-relative grid
                // positions at the composing tempo, so changing BPM later
                // rescales the timeline in proportion instead of drifting.
                vm.backfillAutomationGrid()
            }
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .sheet(item: $editorTarget) { target in
                AutomationEventEditorView(
                    event: target.event,
                    isExisting: target.isExisting
                )
                .environmentObject(vm)
            }
            .alert("Save automation setup", isPresented: $showSaveSetupAlert) {
                TextField("Name", text: $setupName)
                Button("Cancel", role: .cancel) { }
                Button("Save") { vm.saveAutomationSetup(name: setupName) }
            } message: {
                Text("Save the current timeline as a reusable setup you can load onto any patch.")
            }
            .alert(
                "Load setup?",
                isPresented: Binding(
                    get: { pendingLoad != nil },
                    set: { if !$0 { pendingLoad = nil } }
                ),
                presenting: pendingLoad
            ) { setup in
                Button("Cancel", role: .cancel) { pendingLoad = nil }
                Button("Load") {
                    vm.loadAutomationSetup(id: setup.id)
                    pendingLoad = nil
                }
            } message: { setup in
                Text(vm.automation.events.isEmpty
                     ? "Load \u{201C}\(setup.name)\u{201D} onto this patch."
                     : "Replace the current timeline with \u{201C}\(setup.name)\u{201D}?")
            }
        }
    }

    // MARK: - Subviews

    private func setupRow(_ setup: AutomationSetup) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(setup.name)
                    .font(.subheadline)
                    .foregroundStyle(.primary)
                Text("\(setup.timeline.events.count) event\(setup.timeline.events.count == 1 ? "" : "s")")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Image(systemName: "arrow.down.circle")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
    }

    // Loop LENGTH in bars (tempo-accurate). navigationLink style for the
    // same re-render/tap-region robustness as the editor pickers. A bar
    // length defines one cycle; the Repeat picker below controls how many
    // times it plays. Tag -1 = "Manual stop" (no loop, last state holds).
    private var lengthPicker: some View {
        Picker("Length", selection: Binding<Int>(
            get: { vm.automation.totalBars.map { Int($0) } ?? -1 },
            set: { vm.setAutomationBars($0 < 0 ? nil : Double($0)) }
        )) {
            Text("Manual stop").tag(-1)
            ForEach([1, 2, 4, 8, 12, 16, 24, 32, 48, 64], id: \.self) { bars in
                Text("\(bars) bars").tag(bars)
            }
        }
        .pickerStyle(.navigationLink)
    }

    // How many times the loop plays. 0 = forever. Disabled when Length is
    // manual stop (nothing to loop).
    private var repeatPicker: some View {
        Picker("Repeat", selection: Binding<Int>(
            get: { vm.automation.loopCount },
            set: { vm.setAutomationLoopCount($0) }
        )) {
            Text("Forever").tag(0)
            ForEach([1, 2, 3, 4, 6, 8, 12, 16], id: \.self) { n in
                Text(n == 1 ? "Once" : "\(n)×").tag(n)
            }
        }
        .pickerStyle(.navigationLink)
    }

    private func eventRow(_ event: AutomationEvent) -> some View {
        let (bar, beat) = barAndBeat(event)
        return HStack(alignment: .firstTextBaseline, spacing: 12) {
            VStack(alignment: .leading, spacing: 1) {
                Text("Bar \(bar)")
                    .font(.system(.subheadline, design: .monospaced).weight(.semibold))
                    .foregroundStyle(Color.accentColor)
                Text("Beat \(beat)")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            .frame(width: 70, alignment: .leading)
            VStack(alignment: .leading, spacing: 2) {
                Text(rowTitle(event))
                    .font(.subheadline)
                    .foregroundStyle(.primary)
                Text(event.voice.displayName)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Image(systemName: "chevron.right")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
    }

    /// (1-indexed bar, beat-within-bar label) for an event. Beat is
    /// 1-indexed with quarter-beat resolution from the 1/16 grid:
    /// "1", "1.5", "2.5"… Uses the event's canonical `gridSixteenth` when
    /// present (tempo-stable — the row stays put when BPM changes), falling
    /// back to deriving it from the frozen `timeSec` at the session BPM for
    /// legacy events.
    private func barAndBeat(_ event: AutomationEvent) -> (Int, String) {
        let sixteenth: Int
        if let grid = event.gridSixteenth {
            sixteenth = max(0, grid)
        } else {
            let secPerSixteenth = (4.0 * 60.0) / max(1.0, vm.bpm) / 16.0
            sixteenth = Int((event.timeSec / secPerSixteenth).rounded())
        }
        let bar = sixteenth / 16 + 1
        let beat = 1.0 + Double(sixteenth % 16) / 4.0
        if beat == beat.rounded() { return (bar, "\(Int(beat))") }
        var str = String(format: "%.2f", beat)
        while str.hasSuffix("0") { str.removeLast() }
        if str.hasSuffix(".") { str.removeLast() }
        return (bar, str)
    }

    /// Action summary, with transpose direction + chord duration appended
    /// for chord-change events that aren't using the defaults.
    private func rowTitle(_ event: AutomationEvent) -> String {
        var s = event.action.summary()
        guard case .chordChange = event.action else { return s }
        var tags: [String] = []
        if let dir = event.transposeDirection, dir != .nearest {
            tags.append(dir.displayName.lowercased())
        }
        if let dur = event.chordDuration, dur != .hold {
            tags.append(dur.shortLabel)
        }
        if !tags.isEmpty { s += " (\(tags.joined(separator: ", ")))" }
        return s
    }

    // MARK: - Helpers

    private var footerText: String {
        guard let bars = vm.automation.totalBars, bars > 0 else {
            return "Events fire once when their time passes. Manual stop: the last state holds until you tap Stop. Set a bar length to loop."
        }
        let barsInt = Int(bars)
        let count = vm.automation.loopCount
        if count == 0 {
            return "Loops the first \(barsInt) bars forever (until Stop)."
        }
        return "Plays the first \(barsInt) bars \(count == 1 ? "once" : "\(count) times"), then holds the last chord."
    }

    private func defaultNewEvent() -> AutomationEvent {
        // Default to a chord change at the timeline's current "next slot":
        // 30s after the latest event, or 0 if empty. Same key/chord as
        // patch state — user can change before saving.
        //
        // AUTO-ADVANCE: a new event starts where the LAST event's chord
        // ends — its grid position + (chord duration in bars × 16 steps).
        // This turns the timeline into a flowing chord sequencer: add a
        // chord + duration, tap +, and the next event is already positioned
        // at the downbeat after it. No manual time math. Falls back to the
        // last event's own position (for non-chord or Hold events) so +
        // always advances at least to the latest event, and to 0 for an
        // empty timeline.
        //
        // Works in the tempo-relative grid (1/16-bar steps) so the auto-
        // advance spacing is correct at any BPM, and the new event carries
        // a canonical gridSixteenth from creation.
        let secPerSixteenth = (4.0 * 60.0) / max(1.0, vm.bpm) / 16.0
        let sorted = vm.automation.events.sorted {
            ($0.gridSixteenth ?? 0) < ($1.gridSixteenth ?? 0)
        }
        var nextGrid = 0
        if let last = sorted.last {
            nextGrid = last.gridSixteenth
                ?? Int((last.timeSec / secPerSixteenth).rounded())
            if case .chordChange = last.action,
               let bars = last.chordDuration?.bars, bars > 0 {
                nextGrid += Int((bars * 16).rounded())
            }
        }
        return AutomationEvent(
            timeSec: Double(max(0, nextGrid)) * secPerSixteenth,
            gridSixteenth: max(0, nextGrid),
            voice: .all,
            action: .chordChange(
                keyRaw: vm.currentKey.rawValue,
                chordId: vm.currentChord.id
            ),
            chordDuration: .one   // sensible default: 1 bar per chord
        )
    }
}
