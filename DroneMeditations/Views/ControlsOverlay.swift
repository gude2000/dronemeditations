import SwiftUI

/// The full controls layer that floats above the visualization.
/// Tap-to-hide is handled by the parent ContentView.
struct ControlsOverlay: View {
    @EnvironmentObject var vm: DroneViewModel
    @State private var showingChordSheet = false
    @State private var showingPresetSheet = false

    var body: some View {
        VStack(spacing: 12) {
            header

            ScrollView {
                VStack(spacing: 10) {
                    ForEach(0..<4, id: \.self) { i in
                        OscillatorStrip(index: i)
                    }
                    masterRow
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 10)
            }

            TransportView(controller: vm.controller)
                .padding(.horizontal, 12)
                .padding(.bottom, 12)
        }
        .background(Color.black.opacity(0.20).ignoresSafeArea())
        .sheet(isPresented: $showingChordSheet) {
            ChordPickerView()
                .environmentObject(vm)
        }
        .sheet(isPresented: $showingPresetSheet) {
            PresetPickerView()
                .environmentObject(vm)
        }
    }

    // MARK: - Header

    private var header: some View {
        VStack(spacing: 6) {
            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Drone Meditations")
                        .font(.system(.title3, design: .rounded).weight(.semibold))
                        .foregroundStyle(.white)
                    Text(currentDescription)
                        .font(.footnote)
                        .foregroundStyle(.white.opacity(0.7))
                }
                Spacer()
                Button {
                    vm.showChladni.toggle()
                } label: {
                    Image(systemName: vm.showChladni ? "circles.hexagongrid.fill" : "circles.hexagongrid")
                        .font(.system(size: 18, weight: .semibold))
                        .frame(width: 38, height: 38)
                        .background(Circle().fill(Color.white.opacity(0.10)))
                        .foregroundStyle(.white)
                }
                .buttonStyle(.plain)
            }
            HStack(spacing: 8) {
                Button {
                    showingChordSheet = true
                } label: {
                    pillLabel(title: "Chord", value: "\(vm.currentKey.displayName) \(vm.currentChord.name)", system: "music.note.list")
                }
                .buttonStyle(.plain)

                Button {
                    showingPresetSheet = true
                } label: {
                    pillLabel(title: "Preset", value: vm.activePresetName ?? "—", system: "sparkles")
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 14)
        .padding(.top, 6)
    }

    private var currentDescription: String {
        return "\(vm.currentTuning.displayName) · Oct \(vm.currentOctave)"
    }

    private func pillLabel(title: String, value: String, system: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: system)
                .font(.caption.weight(.semibold))
            VStack(alignment: .leading, spacing: 0) {
                Text(title.uppercased())
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.white.opacity(0.6))
                Text(value)
                    .font(.system(.footnote, design: .rounded).weight(.semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
            }
            Image(systemName: "chevron.down")
                .font(.system(size: 9, weight: .bold))
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Capsule().fill(Color.white.opacity(0.10)))
        .foregroundStyle(.white)
    }

    // MARK: - Master volume row

    private var masterRow: some View {
        HStack(spacing: 10) {
            Image(systemName: "speaker.wave.2.fill")
                .foregroundStyle(.secondary)
            Slider(
                value: Binding(
                    get: { vm.masterVolume },
                    set: { vm.setMasterVolume($0) }
                ),
                in: 0.0...1.0
            )
            .tint(.white)
            Text("\(Int(vm.masterVolume * 100))")
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(width: 32, alignment: .trailing)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(.ultraThinMaterial)
        )
    }
}
