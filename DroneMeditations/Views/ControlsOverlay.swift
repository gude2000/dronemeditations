import SwiftUI

/// The full controls layer that floats above the visualization.
/// Tap-to-hide is handled by the parent ContentView.
struct ControlsOverlay: View {
    @EnvironmentObject var vm: DroneViewModel
    @State private var showingChordSheet = false
    @State private var showingPresetSheet = false
    @State private var showingListenSheet = false

    // iPhone landscape reports verticalSizeClass == .compact. iPad and iPhone
    // portrait both report .regular. Use this to switch to space-efficient
    // single-row layouts on iPhone landscape where vertical space is scarce.
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    private var isCompact: Bool { verticalSizeClass == .compact }

    var body: some View {
        VStack(spacing: isCompact ? 6 : 12) {
            if isCompact { compactHeader } else { header }

            ScrollView {
                VStack(spacing: isCompact ? 6 : 10) {
                    ForEach(0..<4, id: \.self) { i in
                        OscillatorStrip(index: i)
                    }
                    masterRow
                }
                .padding(.horizontal, isCompact ? 10 : 12)
                .padding(.bottom, isCompact ? 6 : 10)
            }

            TransportView(controller: vm.controller)
                .padding(.horizontal, isCompact ? 10 : 12)
                .padding(.bottom, isCompact ? 6 : 12)
        }
        .background(
            // Background catches taps on empty panel space and hides the
            // controls. SwiftUI's Button gestures consume taps before they
            // reach this, so the play/pause/sliders/pickers still work.
            Color.black.opacity(0.20)
                .ignoresSafeArea()
                .contentShape(Rectangle())
                .onTapGesture {
                    withAnimation(.easeInOut(duration: 0.22)) { vm.showControls = false }
                }
        )
        .sheet(isPresented: $showingChordSheet) {
            ChordPickerView()
                .environmentObject(vm)
        }
        .sheet(isPresented: $showingPresetSheet) {
            PresetPickerView()
                .environmentObject(vm)
        }
        .sheet(isPresented: $showingListenSheet, onDismiss: {
            vm.micPitch.stop()
        }) {
            ListenSheetView()
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

                Button {
                    vm.toggleDrift()
                } label: {
                    driftPill
                }
                .buttonStyle(.plain)

                Button {
                    showingListenSheet = true
                } label: {
                    pillLabel(title: "Listen", value: "Tune to room", system: "mic.circle")
                }
                .buttonStyle(.plain)

                Button {
                    withAnimation(.easeInOut(duration: 0.22)) {
                        vm.performanceMode = true
                    }
                } label: {
                    pillLabel(title: "Perform", value: "Cymatics", system: "rectangle.fill.on.rectangle.fill")
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 14)
        .padding(.top, 6)
    }

    /// Tinted-when-on "DRIFT" pill that toggles generative slow-drift mode.
    private var driftPill: some View {
        let on = vm.isDriftEnabled
        return HStack(spacing: 6) {
            Image(systemName: on ? "wind.circle.fill" : "wind.circle")
                .font(.caption.weight(.semibold))
            VStack(alignment: .leading, spacing: 0) {
                Text("DRIFT")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(on ? Color(red: 0.55, green: 0.76, blue: 1.0) : .white.opacity(0.6))
                Text(on ? "On" : "Off")
                    .font(.system(.footnote, design: .rounded).weight(.semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(
            Capsule().fill(on ? Color(red: 0.55, green: 0.76, blue: 1.0).opacity(0.22) : Color.white.opacity(0.10))
        )
        .overlay(
            Capsule().stroke(on ? Color(red: 0.55, green: 0.76, blue: 1.0).opacity(0.40) : .clear, lineWidth: 1)
        )
        .foregroundStyle(.white)
    }

    // MARK: - Compact header (iPhone landscape)

    /// Single-row header: title (small) + chord pill + preset pill + chladni
    /// toggle. Saves ~40-50px of vertical space vs. the full header.
    private var compactHeader: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 0) {
                Text("Drone Meditations")
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white)
                Text(currentDescription)
                    .font(.system(size: 9))
                    .foregroundStyle(.white.opacity(0.6))
            }

            Spacer(minLength: 6)

            Button { showingChordSheet = true } label: {
                pillLabel(title: "Chord", value: "\(vm.currentKey.displayName) \(vm.currentChord.name)", system: "music.note.list")
            }
            .buttonStyle(.plain)

            Button { showingPresetSheet = true } label: {
                pillLabel(title: "Preset", value: vm.activePresetName ?? "—", system: "sparkles")
            }
            .buttonStyle(.plain)

            Button { vm.showChladni.toggle() } label: {
                Image(systemName: vm.showChladni ? "circles.hexagongrid.fill" : "circles.hexagongrid")
                    .font(.system(size: 14, weight: .semibold))
                    .frame(width: 30, height: 30)
                    .background(Circle().fill(Color.white.opacity(0.10)))
                    .foregroundStyle(.white)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 14)
        .padding(.top, 4)
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
        .padding(.horizontal, isCompact ? 12 : 14)
        .padding(.vertical, isCompact ? 5 : 10)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(.ultraThinMaterial)
        )
    }
}
