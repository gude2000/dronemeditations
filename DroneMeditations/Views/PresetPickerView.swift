import SwiftUI

struct PresetPickerView: View {
    @EnvironmentObject var vm: DroneViewModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text("Binaural beats require headphones to take effect.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                .listRowBackground(Color.white.opacity(0.04))

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
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .preferredColorScheme(.dark)
    }
}
