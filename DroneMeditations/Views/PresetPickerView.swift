import SwiftUI

struct PresetPickerView: View {
    @EnvironmentObject var vm: DroneViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var showingSaveAlert = false
    @State private var newPresetName = ""

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text("Binaural beats require headphones to take effect.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                .listRowBackground(Color.white.opacity(0.04))

                if !vm.userPresets.isEmpty {
                    Section("Your Presets") {
                        ForEach(vm.userPresets) { p in
                            HStack {
                                Button {
                                    vm.loadUserPreset(id: p.id)
                                    dismiss()
                                } label: {
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(p.name)
                                            .font(.system(.body, design: .rounded).weight(.medium))
                                            .foregroundStyle(.white)
                                        Text(p.createdAt.formatted(date: .abbreviated, time: .shortened))
                                            .font(.footnote)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                                .buttonStyle(.plain)
                                Spacer()
                                Button {
                                    vm.deleteUserPreset(id: p.id)
                                } label: {
                                    Image(systemName: "trash")
                                        .foregroundStyle(.red.opacity(0.85))
                                }
                                .buttonStyle(.plain)
                            }
                            .listRowBackground(
                                vm.activePresetName == p.name
                                    ? Color.white.opacity(0.15)
                                    : Color.white.opacity(0.04)
                            )
                        }
                    }
                }

                ForEach(Preset.Category.allCases, id: \.self) { cat in
                    if let presets = Preset.byCategory[cat] {
                        Section(cat.rawValue) {
                            ForEach(presets) { p in
                                Button {
                                    vm.applyPreset(p)
                                    dismiss()
                                } label: {
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(p.name)
                                            .font(.system(.body, design: .rounded).weight(.medium))
                                            .foregroundStyle(.white)
                                        if let sub = p.subtitle {
                                            Text(sub)
                                                .font(.footnote)
                                                .foregroundStyle(.secondary)
                                        }
                                    }
                                    .padding(.vertical, 2)
                                }
                                .listRowBackground(
                                    vm.activePresetName == p.name
                                        ? Color.white.opacity(0.15)
                                        : Color.white.opacity(0.04)
                                )
                            }
                        }
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background(Color.black.ignoresSafeArea())
            .navigationTitle("Presets")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Save Current") {
                        newPresetName = ""
                        showingSaveAlert = true
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .alert("Save Preset", isPresented: $showingSaveAlert) {
                TextField("Name", text: $newPresetName)
                Button("Save") {
                    vm.saveCurrentAsUserPreset(named: newPresetName)
                }
                Button("Cancel", role: .cancel) { }
            } message: {
                Text("Saves all 4 oscillator settings, filter, reverb, delay, LFOs, and any loaded samples.")
            }
        }
        .preferredColorScheme(.dark)
    }
}
