import SwiftUI

/// Pick two presets, then either drag the slider for manual morph OR pick a
/// duration + tap Play to auto-interpolate every per-voice parameter
/// continuously between them over time. Frequencies use log interpolation;
/// mixes/depths use linear; discrete fields (waveform, filter type, LFO
/// shape) swap at the midpoint.
struct MorphSheetView: View {
    @EnvironmentObject var vm: DroneViewModel
    @Environment(\.dismiss) private var dismiss

    // Tracks which dropdown is showing its preset picker sheet.
    // Replaces the previous Menu approach which couldn't scroll 80+ items
    // reliably on iOS 18 and sometimes swallowed taps.
    private enum PickerTarget: Identifiable {
        case from, to
        var id: String { self == .from ? "from" : "to" }
        var label: String { self == .from ? "From" : "To" }
    }
    @State private var activePicker: PickerTarget?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    // Both rows open a full-screen sheet with a scrollable
                    // List — same pattern the main Preset picker uses, which
                    // works reliably. SwiftUI Menu choked on 80+ items
                    // across many sections (no scrolling, first-tap drops).
                    presetMenuRow(
                        label: "From",
                        current: vm.morphFromName
                    ) { activePicker = .from }
                    presetMenuRow(
                        label: "To",
                        current: vm.morphToName
                    ) { activePicker = .to }
                } header: {
                    Text("Presets")
                } footer: {
                    Text("Pick a From and a To. Drag the slider to morph manually, or pick a duration + tap Play to auto-morph over time.")
                }

                Section {
                    HStack {
                        Text(vm.morphFromName ?? "—")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: 110, alignment: .trailing)
                            .lineLimit(2)
                        Slider(value: Binding(
                            get: { vm.morphAmount },
                            set: { vm.setMorphAmount($0) }
                        ), in: 0...1)
                        Text(vm.morphToName ?? "—")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: 110, alignment: .leading)
                            .lineLimit(2)
                    }
                    Text(readoutText)
                        .font(.system(.headline, design: .monospaced))
                        .foregroundStyle(Color(red: 0.81, green: 0.71, blue: 0.92))
                        .frame(maxWidth: .infinity, alignment: .center)
                } header: {
                    Text("Amount")
                }

                Section {
                    // Duration picker chips — same look as the per-osc
                    // timing menu. Tap to set; the active value gets the
                    // purple highlight.
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 4), spacing: 8) {
                        ForEach(durationOptions, id: \.sec) { opt in
                            durationChip(label: opt.label, sec: opt.sec)
                        }
                    }
                    // Active duration readout (formatted nicely).
                    Text("Duration: \(formatDuration(vm.morphDurationSec))")
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .center)

                    // Play / Pause / Reset row.
                    HStack(spacing: 14) {
                        Button {
                            if vm.morphIsRunning { vm.pauseMorph() } else { vm.startMorph() }
                        } label: {
                            HStack {
                                Image(systemName: vm.morphIsRunning ? "pause.fill" : "play.fill")
                                Text(vm.morphIsRunning ? "Pause" : "Play")
                                    .font(.system(.body, design: .rounded).weight(.semibold))
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 8)
                            .background(
                                RoundedRectangle(cornerRadius: 10, style: .continuous)
                                    .fill(vm.morphIsRunning
                                          ? Color(red: 1.0, green: 0.78, blue: 0.45).opacity(0.30)
                                          : Color(red: 0.81, green: 0.71, blue: 0.92).opacity(0.30))
                            )
                            .foregroundStyle(.primary)
                        }
                        .buttonStyle(.plain)
                        .disabled(vm.morphFromName == nil || vm.morphToName == nil)

                        Button {
                            vm.resetMorphPosition()
                        } label: {
                            HStack {
                                Image(systemName: "arrow.counterclockwise")
                                Text("Reset").font(.system(.body, design: .rounded).weight(.semibold))
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 8)
                            .background(
                                RoundedRectangle(cornerRadius: 10, style: .continuous)
                                    .fill(Color.gray.opacity(0.20))
                            )
                            .foregroundStyle(.primary)
                        }
                        .buttonStyle(.plain)
                    }

                    Toggle(isOn: Binding(
                        get: { vm.morphIsPingPong },
                        set: { vm.setMorphPingPong($0) }
                    )) {
                        VStack(alignment: .leading) {
                            Text("Ping-pong")
                            Text("Bounce back and forth between From and To")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                } header: {
                    Text("Auto-morph")
                } footer: {
                    Text("The morph keeps running when you close this sheet — you can watch Chladni evolve through the full duration in Performance mode.")
                }

                Section {
                    Button(role: .destructive) {
                        vm.clearMorph()
                    } label: {
                        Label("Reset (clear morph)", systemImage: "xmark.circle")
                    }
                }
            }
            .navigationTitle("Morph Between Presets")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
            .sheet(item: $activePicker) { target in
                MorphPresetPicker(
                    title: "Pick \(target.label)",
                    current: target == .from ? vm.morphFromName : vm.morphToName,
                    groupedPresets: groupedPresets
                ) { picked in
                    if target == .from {
                        vm.setMorphFrom(picked)
                    } else {
                        vm.setMorphTo(picked)
                    }
                    activePicker = nil
                }
                .environmentObject(vm)
            }
        }
    }

    private var readoutText: String {
        let pct = Int((vm.morphAmount * 100).rounded())
        if vm.morphFromName == nil || vm.morphToName == nil {
            return "\(pct)%  (pick From + To)"
        }
        if vm.morphIsRunning {
            let dirGlyph = vm.morphIsPingPong
                ? (vm.morphAmount < 1.0 ? "▶" : "◀")
                : "▶"
            return "\(dirGlyph) \(pct)%"
        }
        return "\(pct)%"
    }

    private struct DurOpt { let label: String; let sec: Double }
    private let durationOptions: [DurOpt] = [
        .init(label: "30 s",  sec: 30),
        .init(label: "1 min", sec: 60),
        .init(label: "3 min", sec: 180),
        .init(label: "5 min", sec: 300),
        .init(label: "10 min", sec: 600),
        .init(label: "20 min", sec: 1200),
        .init(label: "30 min", sec: 1800),
        .init(label: "60 min", sec: 3600)
    ]

    /// One row for From or To. Tapping it triggers `onTap` which opens
    /// the MorphPresetPicker sheet (see body's .sheet modifier). Sheet
    /// presentation gives us proper scrollable List behavior — SwiftUI
    /// Menu choked on 80+ presets across many sections.
    @ViewBuilder
    private func presetMenuRow(
        label: String,
        current: String?,
        onTap: @escaping () -> Void
    ) -> some View {
        Button(action: onTap) {
            HStack {
                Text(label)
                    .foregroundStyle(.primary)
                Spacer()
                Text(current ?? "— pick —")
                    .foregroundStyle(current == nil ? Color.secondary : Color.accentColor)
                    .lineLimit(1)
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func durationChip(label: String, sec: Double) -> some View {
        let isActive = abs(vm.morphDurationSec - sec) < 0.5
        return Button {
            vm.setMorphDuration(sec)
        } label: {
            Text(label)
                .font(.system(.caption, design: .rounded).weight(.semibold))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(isActive
                              ? Color(red: 0.81, green: 0.71, blue: 0.92).opacity(0.35)
                              : Color.gray.opacity(0.15))
                )
                .foregroundStyle(.primary)
        }
        .buttonStyle(.plain)
    }

    private func formatDuration(_ sec: Double) -> String {
        let s = Int(sec.rounded())
        if s < 60 { return "\(s) s" }
        let m = s / 60
        let rem = s % 60
        if rem == 0 { return "\(m) min" }
        return "\(m) min \(rem) s"
    }

    /// Build category groupings for the picker. We use Preset.Category
    /// (an enum) so the order matches the rest of the app's preset list.
    /// User-saved presets get a "My Presets" group at the top of the menu.
    private var groupedPresets: [(category: String, presets: [PresetMenuRow])] {
        var groups: [(category: String, presets: [PresetMenuRow])] = []
        // User presets first so they're easiest to find.
        if !vm.userPresets.isEmpty {
            groups.append((
                category: "My Presets",
                presets: vm.userPresets.map { PresetMenuRow(name: $0.name) }
            ))
        }
        for cat in Preset.Category.allCases {
            let list = Preset.byCategory[cat] ?? []
            if !list.isEmpty {
                groups.append((
                    category: cat.rawValue,
                    presets: list.map { PresetMenuRow(name: $0.name) }
                ))
            }
        }
        return groups
    }
}

/// Lightweight row type so the picker doesn't care whether a preset is
/// built-in or user-saved — both contribute their name. The morph applier
/// resolves names back to voices via `morphVoicesFor`.
private struct PresetMenuRow: Identifiable {
    var id: String { name }
    let name: String
}

/// Sheet that lists all presets grouped by category and lets the user
/// pick one for the morph From/To slot. A standard SwiftUI List scrolls
/// reliably even with 80+ items across many sections — unlike the
/// previous SwiftUI Menu approach which choked on tall content on
/// iOS 18.
private struct MorphPresetPicker: View {
    @EnvironmentObject var vm: DroneViewModel
    @Environment(\.dismiss) private var dismiss
    let title: String
    let current: String?
    let groupedPresets: [(category: String, presets: [PresetMenuRow])]
    let onPick: (String?) -> Void

    var body: some View {
        NavigationStack {
            List {
                // Allow clearing the selection — useful if the user wants
                // to back out of a morph without dismissing the parent
                // morph sheet.
                Section {
                    Button {
                        onPick(nil)
                    } label: {
                        HStack {
                            Text("— Clear —")
                                .foregroundStyle(.secondary)
                            Spacer()
                            if current == nil {
                                Image(systemName: "checkmark")
                                    .foregroundStyle(Color.accentColor)
                            }
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
                ForEach(groupedPresets, id: \.category) { group in
                    Section(group.category) {
                        ForEach(group.presets) { p in
                            Button {
                                onPick(p.name)
                            } label: {
                                HStack {
                                    Text(p.name)
                                        .foregroundStyle(.primary)
                                    Spacer()
                                    if p.name == current {
                                        Image(systemName: "checkmark")
                                            .foregroundStyle(Color.accentColor)
                                    }
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
        .preferredColorScheme(.dark)
    }
}
