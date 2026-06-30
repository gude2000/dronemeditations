import SwiftUI

/// Top-level UI for editing the AutomationTimeline. Opens from the
/// AUTOMATION pill in the controls header. Lists events in time order;
/// tapping a row opens an editor sheet for that event. Plus a Duration
/// / Loop section at the top — Duration = 0 means "until manual stop"
/// per the v1.1 locked design.
struct AutomationSheetView: View {
    @EnvironmentObject var vm: DroneViewModel
    @Environment(\.dismiss) private var dismiss

    @State private var editingEvent: AutomationEvent?
    @State private var showingNewEvent = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    durationRow
                    Toggle(isOn: Binding(
                        get: { vm.automation.loop },
                        set: { vm.setAutomationLoop($0) }
                    )) {
                        Text("Loop").font(.subheadline)
                    }
                    .disabled(vm.automation.totalDurationSec <= 0)
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
                                editingEvent = event
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
                            showingNewEvent = true
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
            }
            .navigationTitle("Automation")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .sheet(item: $editingEvent) { event in
                AutomationEventEditorView(event: event, isExisting: true)
                    .environmentObject(vm)
            }
            .sheet(isPresented: $showingNewEvent) {
                AutomationEventEditorView(event: defaultNewEvent(), isExisting: false)
                    .environmentObject(vm)
            }
        }
    }

    // MARK: - Subviews

    private var durationRow: some View {
        HStack {
            Text("Duration").font(.subheadline)
            Spacer()
            Menu {
                Button("Manual stop (0)") { vm.setAutomationDuration(0) }
                Divider()
                ForEach([60, 180, 300, 600, 900, 1200, 1800, 3600], id: \.self) { sec in
                    Button(formatDuration(Double(sec))) {
                        vm.setAutomationDuration(Double(sec))
                    }
                }
            } label: {
                Text(vm.automation.totalDurationSec == 0
                     ? "Manual stop"
                     : formatDuration(vm.automation.totalDurationSec))
                    .font(.system(.subheadline, design: .monospaced))
                    .foregroundStyle(Color.accentColor)
            }
        }
    }

    private func eventRow(_ event: AutomationEvent) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(formatTime(event.timeSec))
                .font(.system(.subheadline, design: .monospaced).weight(.semibold))
                .foregroundStyle(Color.accentColor)
                .frame(width: 56, alignment: .leading)
            VStack(alignment: .leading, spacing: 2) {
                Text(event.action.summary())
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

    // MARK: - Helpers

    private var footerText: String {
        if vm.automation.totalDurationSec <= 0 {
            return "Events fire once when their time passes during playback. The timeline ends when you tap Stop."
        }
        return vm.automation.loop
            ? "Timeline wraps every \(formatDuration(vm.automation.totalDurationSec))."
            : "Events fire once. Timeline ends at \(formatDuration(vm.automation.totalDurationSec)) or on manual Stop."
    }

    private func defaultNewEvent() -> AutomationEvent {
        // Default to a chord change at the timeline's current "next slot":
        // 30s after the latest event, or 0 if empty. Same key/chord as
        // patch state — user can change before saving.
        let nextTime = (vm.automation.events.map(\.timeSec).max() ?? -30) + 30
        return AutomationEvent(
            timeSec: max(0, nextTime),
            voice: .all,
            action: .chordChange(
                keyRaw: vm.currentKey.rawValue,
                chordId: vm.currentChord.id
            )
        )
    }

    private func formatTime(_ sec: Double) -> String {
        let s = Int(sec.rounded(.down))
        return String(format: "%d:%02d", s / 60, s % 60)
    }

    private func formatDuration(_ sec: Double) -> String {
        let s = Int(sec.rounded(.down))
        if s % 60 == 0 {
            return "\(s / 60) min"
        }
        return String(format: "%d:%02d", s / 60, s % 60)
    }
}
