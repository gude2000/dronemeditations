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
                                    // contentShape makes the whole row a tap
                                    // target — without it, only the text
                                    // glyphs are tappable and the user has to
                                    // tap precisely on a letter.
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .contentShape(Rectangle())
                                }
                                // .buttonStyle(.plain) is REQUIRED here.
                                // Without it, SwiftUI's List wraps the button
                                // in its own row-selection gesture which
                                // swallows the first tap (the user has to tap
                                // twice). The User Presets section already
                                // has this; this section was missing it.
                                .buttonStyle(.plain)
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
            // Use a SwiftUI sheet rather than a system .alert() to avoid
            // an audible "crackle" when the alert appears or dismisses.
            // Alerts with text fields force iOS to swap the audio session
            // (because the system keyboard is its own audio route consumer);
            // SwiftUI sheets stay in our process and don't disturb the
            // session.
            .sheet(isPresented: $showingSaveAlert) {
                SavePresetSheet(name: $newPresetName) {
                    vm.saveCurrentAsUserPreset(named: newPresetName)
                }
                .presentationDetents([.height(260)])
            }
        }
        .preferredColorScheme(.dark)
    }
}

/// Compact modal sheet for naming a new user preset. Replaces the iOS
/// system .alert() (which caused audible crackle from audio-session
/// keyboard handoff). Submits on Save tap or Enter; Cancel closes
/// without saving.
private struct SavePresetSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Binding var name: String
    let onSave: () -> Void
    @FocusState private var nameFieldFocused: Bool

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Preset name", text: $name)
                        .focused($nameFieldFocused)
                        .submitLabel(.done)
                        .onSubmit { save() }
                } footer: {
                    Text("Saves all 4 oscillator settings, filter, reverb, delay, LFOs, and any loaded samples.")
                }
            }
            .navigationTitle("Save Preset")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Save") { save() }
                        .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .onAppear {
                // Auto-focus the field so the user can start typing
                // immediately (matches the old alert's behavior).
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                    nameFieldFocused = true
                }
            }
        }
        .preferredColorScheme(.dark)
    }

    private func save() {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        onSave()
        dismiss()
    }
}
