import SwiftUI

/// The full controls layer that floats above the visualization.
/// Tap-to-hide is handled by the parent ContentView.
struct ControlsOverlay: View {
    @EnvironmentObject var vm: DroneViewModel
    @State private var showingChordSheet = false
    @State private var showingPresetSheet = false
    @State private var showingListenSheet = false
    @State private var showingJourneySheet = false

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
        .sheet(isPresented: $showingJourneySheet) {
            JourneyPickerView()
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

                Menu {
                    // Section 1: singles (off, glacial, simple all-voice journeys).
                    Section {
                        ForEach(DroneViewModel.driftScenes.filter { !$0.isCoordinated }) { scene in
                            sceneMenuButton(scene)
                        }
                    }
                    // Section 2: coordinated multi-voice scenes.
                    Section("Coordinated scenes") {
                        ForEach(DroneViewModel.driftScenes.filter { $0.isCoordinated }) { scene in
                            sceneMenuButton(scene)
                        }
                    }
                } label: {
                    driftPill
                }
                .menuStyle(.borderlessButton)

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

                Button { showingJourneySheet = true } label: { journeyPill }
                    .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 14)
        .padding(.top, 6)
    }

    /// Pill that opens the journeys sheet. Amber-tinted while a journey is
    /// running; shows journey name + stage X/N.
    private var journeyPill: some View {
        let active = vm.activeJourneyId != nil
        let value: String
        if let j = vm.activeJourney {
            let stage = min(vm.journeyStageIndex + 1, j.stages.count)
            value = "\(j.name) · \(stage)/\(j.stages.count)"
        } else {
            value = "Off"
        }
        return HStack(spacing: 6) {
            Image(systemName: active ? "map.fill" : "map")
                .font(.caption.weight(.semibold))
            VStack(alignment: .leading, spacing: 0) {
                Text("JOURNEY")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(active ? Color(red: 1.0, green: 0.85, blue: 0.55) : .white.opacity(0.6))
                Text(value)
                    .font(.system(.footnote, design: .rounded).weight(.semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
            }
            Image(systemName: "chevron.down").font(.system(size: 9, weight: .bold))
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(
            Capsule().fill(active ? Color(red: 1.0, green: 0.85, blue: 0.55).opacity(0.20) : Color.white.opacity(0.10))
        )
        .overlay(
            Capsule().stroke(active ? Color(red: 1.0, green: 0.85, blue: 0.55).opacity(0.40) : .clear, lineWidth: 1)
        )
        .foregroundStyle(.white)
    }

    /// Pill that opens the drift-scene menu. Tinted whenever the active
    /// scene is anything other than "Off"; shows the current scene name
    /// or "Custom" if individual voices have been tweaked.
    private var driftPill: some View {
        let on = vm.driftSceneId != "off"
        let label: String
        if let name = vm.driftScene?.name { label = name }
        else if vm.driftSceneId == "custom" { label = "Custom" }
        else { label = "Off" }
        return HStack(spacing: 6) {
            Image(systemName: on ? "wind.circle.fill" : "wind.circle")
                .font(.caption.weight(.semibold))
            VStack(alignment: .leading, spacing: 0) {
                Text("DRIFT")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(on ? Color(red: 0.55, green: 0.76, blue: 1.0) : .white.opacity(0.6))
                Text(label)
                    .font(.system(.footnote, design: .rounded).weight(.semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
            }
            Image(systemName: "chevron.down")
                .font(.system(size: 9, weight: .bold))
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

    private func sceneMenuButton(_ scene: DroneViewModel.DriftScene) -> some View {
        Button {
            vm.setDriftScene(scene.id)
        } label: {
            if scene.id == vm.driftSceneId {
                Label(scene.name, systemImage: "checkmark")
            } else {
                Text(scene.name)
            }
        }
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

            // All pills in a horizontal scroll so they fit on narrow
            // landscape screens — previously only Chord + Preset were
            // visible; Drift/Listen/Perform were cut off.
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    Button { showingChordSheet = true } label: {
                        pillLabel(title: "Chord", value: "\(vm.currentKey.displayName) \(vm.currentChord.name)", system: "music.note.list")
                    }
                    .buttonStyle(.plain)

                    Button { showingPresetSheet = true } label: {
                        pillLabel(title: "Preset", value: vm.activePresetName ?? "—", system: "sparkles")
                    }
                    .buttonStyle(.plain)

                    Menu {
                        Section {
                            ForEach(DroneViewModel.driftScenes.filter { !$0.isCoordinated }) { scene in
                                sceneMenuButton(scene)
                            }
                        }
                        Section("Coordinated scenes") {
                            ForEach(DroneViewModel.driftScenes.filter { $0.isCoordinated }) { scene in
                                sceneMenuButton(scene)
                            }
                        }
                    } label: {
                        driftPill
                    }
                    .menuStyle(.borderlessButton)

                    Button { showingListenSheet = true } label: {
                        pillLabel(title: "Listen", value: "Tune", system: "mic.circle")
                    }
                    .buttonStyle(.plain)

                    Button {
                        withAnimation(.easeInOut(duration: 0.22)) { vm.performanceMode = true }
                    } label: {
                        pillLabel(title: "Perform", value: "Cymatics", system: "rectangle.fill.on.rectangle.fill")
                    }
                    .buttonStyle(.plain)

                    Button { showingJourneySheet = true } label: { journeyPill }
                        .buttonStyle(.plain)
                }
            }
            .scrollClipDisabled()  // let menus open beyond the scroll bounds

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

            // Subtle haptics toggle — taps the device in time with the
            // slowest active LFO. Off by default.
            Button {
                vm.haptics.isEnabled.toggle()
            } label: {
                Image(systemName: vm.haptics.isEnabled ? "waveform.path" : "waveform.path")
                    .font(.system(size: 14, weight: .semibold))
                    .frame(width: 28, height: 28)
                    .background(
                        Circle().fill(
                            vm.haptics.isEnabled
                                ? Color(red: 0.55, green: 0.76, blue: 1.0).opacity(0.30)
                                : Color.white.opacity(0.10)
                        )
                    )
                    .foregroundStyle(.white)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Toggle haptic feedback")
        }
        .padding(.horizontal, isCompact ? 12 : 14)
        .padding(.vertical, isCompact ? 5 : 10)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(.ultraThinMaterial)
        )
    }
}
