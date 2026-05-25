import SwiftUI

/// Pick two presets, then drag the slider to interpolate every per-voice
/// parameter continuously between them. Frequencies use log interpolation;
/// mixes/depths use linear; discrete fields (waveform, filter type, LFO
/// shape) swap at the midpoint.
struct MorphSheetView: View {
    @EnvironmentObject var vm: DroneViewModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("From", selection: Binding(
                        get: { vm.morphFromName ?? "" },
                        set: { vm.setMorphFrom($0.isEmpty ? nil : $0) }
                    )) {
                        Text("— pick —").tag("")
                        ForEach(groupedPresets, id: \.category) { group in
                            Section(group.category) {
                                ForEach(group.presets, id: \.name) { p in
                                    Text(p.name).tag(p.name)
                                }
                            }
                        }
                    }
                    .pickerStyle(.menu)
                    Picker("To", selection: Binding(
                        get: { vm.morphToName ?? "" },
                        set: { vm.setMorphTo($0.isEmpty ? nil : $0) }
                    )) {
                        Text("— pick —").tag("")
                        ForEach(groupedPresets, id: \.category) { group in
                            Section(group.category) {
                                ForEach(group.presets, id: \.name) { p in
                                    Text(p.name).tag(p.name)
                                }
                            }
                        }
                    }
                    .pickerStyle(.menu)
                } header: {
                    Text("Presets")
                } footer: {
                    Text("Pick a From and a To, then drag the slider below.")
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
        }
    }

    private var readoutText: String {
        let pct = Int((vm.morphAmount * 100).rounded())
        if vm.morphFromName == nil || vm.morphToName == nil {
            return "\(pct)%  (pick From + To)"
        }
        return "\(pct)%"
    }

    /// Build category groupings for the picker. We use Preset.Category
    /// (an enum) so the order matches the rest of the app's preset list.
    private var groupedPresets: [(category: String, presets: [Preset])] {
        Preset.Category.allCases.compactMap { cat in
            let list = Preset.byCategory[cat] ?? []
            return list.isEmpty ? nil : (category: cat.rawValue, presets: list)
        }
    }
}
