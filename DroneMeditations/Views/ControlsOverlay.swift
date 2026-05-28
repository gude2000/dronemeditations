import SwiftUI

/// The full controls layer that floats above the visualization.
/// Tap-to-hide is handled by the parent ContentView.
struct ControlsOverlay: View {
    @EnvironmentObject var vm: DroneViewModel
    @State private var showingChordSheet = false
    @State private var showingPresetSheet = false
    @State private var showingListenSheet = false
    @State private var showingJourneySheet = false
    @State private var showingMorphSheet = false

    /// Transient banner shown after a snapshot save attempt — "Saved to Photos"
    /// on success, error string on failure. Auto-clears after 2 seconds.
    @State private var snapshotToast: String?
    @State private var snapshotToastIsError: Bool = false
    @State private var snapshotToastTask: Task<Void, Never>?

    // iPhone landscape reports verticalSizeClass == .compact. iPad and iPhone
    // portrait both report .regular. Use this to switch to space-efficient
    // single-row layouts on iPhone landscape where vertical space is scarce.
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    private var isCompact: Bool { verticalSizeClass == .compact }

    // iPhone reports horizontalSizeClass == .compact in every orientation;
    // iPad reports .regular. Per-device width cap:
    //   - iPad (regular):  1360pt — near edge-to-edge on iPad Pro 13"
    //     landscape (1366pt → ~3pt gutter per side). Portrait is fine
    //     since the largest iPad portrait is 1024pt, well under the cap.
    //   - iPhone portrait: 900pt — a no-op since iPhone is < 500pt wide.
    //   - iPhone landscape: .infinity — iPhone Pro Max in landscape is
    //     956pt, so a 900pt cap left ~28pt of wasted gutter on each
    //     side. Let the strips fill the whole device width.
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    private var panelMaxWidth: CGFloat {
        if horizontalSizeClass == .regular { return 1360 }
        if isCompact { return .infinity }      // iPhone landscape
        return 900                             // iPhone portrait
    }

    var body: some View {
        ZStack {
            // Full-screen tap-catching layer — hides the controls when the
            // user taps empty space. Kept as the bottom layer of the ZStack
            // so it spans the entire iPad canvas; the bounded controls VStack
            // sits centered on top. SwiftUI's Button gestures consume taps
            // before they reach this, so play/pause/sliders/pickers still work.
            Color.black.opacity(0.20)
                .ignoresSafeArea()
                .contentShape(Rectangle())
                .onTapGesture {
                    withAnimation(.easeInOut(duration: 0.22)) { vm.showControls = false }
                }

            VStack(spacing: isCompact ? 6 : 12) {
                if isCompact { compactHeader } else { header }

                // OSC nav pills + scrollable strip column. The
                // ScrollViewReader lets the nav pills above jump
                // directly to a chosen oscillator without the user
                // having to scroll the whole strip column to find
                // OSC 3 / OSC 4. Each strip is tagged with .id("osc-N")
                // so scrollTo can find it. Animation gives a smooth
                // glide rather than a jarring jump.
                ScrollViewReader { proxy in
                    VStack(spacing: isCompact ? 4 : 6) {
                        // Nav pills — 4 compact pills aligned with the
                        // pill row above. Tap → scroll to that osc.
                        // Plus a dice button at the right: randomizes
                        // the WHOLE preset (all 4 voices + chord) but
                        // preserves volume levels so the user isn't
                        // blasted by a roll.
                        HStack(spacing: isCompact ? 6 : 8) {
                            ForEach(0..<4, id: \.self) { i in
                                Button {
                                    withAnimation(.easeInOut(duration: 0.32)) {
                                        proxy.scrollTo("osc-\(i)", anchor: .top)
                                    }
                                } label: {
                                    Text("OSC \(i + 1)")
                                        .font(.system(size: isCompact ? 9 : 10, weight: .semibold))
                                        .padding(.horizontal, isCompact ? 8 : 10)
                                        .padding(.vertical, isCompact ? 3 : 4)
                                        .background(
                                            Capsule().fill(Color.white.opacity(0.10))
                                        )
                                        .overlay(
                                            Capsule().stroke(Color.white.opacity(0.18), lineWidth: 1)
                                        )
                                        .foregroundStyle(.white.opacity(0.85))
                                }
                                .buttonStyle(.plain)
                            }

                            // Global randomize. Sits flush against the
                            // OSC pills since it operates on all of them
                            // at once.
                            Button {
                                vm.randomizeAll()
                            } label: {
                                Image(systemName: "dice")
                                    .font(.system(size: isCompact ? 11 : 12, weight: .semibold))
                                    .padding(.horizontal, isCompact ? 8 : 10)
                                    .padding(.vertical, isCompact ? 3 : 4)
                                    .background(
                                        Capsule().fill(Color.accentColor.opacity(0.25))
                                    )
                                    .overlay(
                                        Capsule().stroke(Color.accentColor.opacity(0.50), lineWidth: 1)
                                    )
                                    .foregroundStyle(.white)
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("Randomize all oscillators")

                            // Undo last randomize — one-level undo back
                            // to the snapshot saved before the most
                            // recent dice tap. Greyed out when no
                            // snapshot is available (fresh launch, or
                            // already undone).
                            Button {
                                vm.undoRandomize()
                            } label: {
                                Image(systemName: "arrow.uturn.backward")
                                    .font(.system(size: isCompact ? 11 : 12, weight: .semibold))
                                    .padding(.horizontal, isCompact ? 8 : 10)
                                    .padding(.vertical, isCompact ? 3 : 4)
                                    .background(
                                        Capsule().fill(Color.white.opacity(
                                            vm.canUndoRandomize ? 0.18 : 0.05))
                                    )
                                    .overlay(
                                        Capsule().stroke(Color.white.opacity(
                                            vm.canUndoRandomize ? 0.35 : 0.10), lineWidth: 1)
                                    )
                                    .foregroundStyle(.white.opacity(
                                        vm.canUndoRandomize ? 0.90 : 0.35))
                            }
                            .buttonStyle(.plain)
                            .disabled(!vm.canUndoRandomize)
                            .accessibilityLabel("Undo last randomize")
                        }
                        .padding(.horizontal, isCompact ? 6 : 12)

                        ScrollView {
                            VStack(spacing: isCompact ? 6 : 10) {
                                ForEach(0..<4, id: \.self) { i in
                                    OscillatorStrip(index: i)
                                        .id("osc-\(i)")
                                }
                                masterRow
                            }
                            .padding(.horizontal, isCompact ? 6 : 12)
                            .padding(.bottom, isCompact ? 6 : 10)
                        }
                    }
                }

                TransportView(controller: vm.controller)
                    .padding(.horizontal, isCompact ? 6 : 12)
                    .padding(.bottom, isCompact ? 1 : 4)

                // Copyright + Manual link inlined under the transport. Sits at
                // the very bottom of the controls panel so it never overlaps
                // the transport, the pill row, or (when controls are hidden)
                // the ChladniMiniControls strip — which has its own inlined
                // copy. Replaces the old free-floating copyrightOverlay that
                // collided with the transport area in portrait + landscape.
                CopyrightStrip()
                    .padding(.bottom, isCompact ? 1 : 8)
            }
            // On iPhone (compact size class) the cap of 900pt is a no-op since
            // iPhone screens are < 900pt wide. On iPad it widens to 1200pt so
            // the strips don't sit in the middle of an oversized canvas with
            // ~1.5" of wasted margin on each side (iPad Pro 13" portrait is
            // 1024pt; landscape 1366pt — 1200pt fills portrait and leaves
            // modest landscape gutters).
            .frame(maxWidth: panelMaxWidth)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .sheet(isPresented: $showingChordSheet) {
            ChordPickerView()
                .environmentObject(vm)
        }
        .sheet(isPresented: $showingPresetSheet) {
            PresetPickerView()
                .environmentObject(vm)
        }
        .sheet(isPresented: $showingListenSheet, onDismiss: {
            // Defer mic teardown to the next runloop tick. The cleanup
            // fires multiple @Published changes (isListening / detectedHz
            // / inputLevel) which trigger SwiftUI diff passes — running
            // them synchronously here can hold the @MainActor for several
            // frames AFTER the sheet has dismissed, making the parent UI
            // (Play button) feel unresponsive for ~1 s.
            Task { @MainActor in
                vm.micPitch.stop()
            }
        }) {
            ListenSheetView()
                .environmentObject(vm)
        }
        .sheet(isPresented: $showingJourneySheet) {
            JourneyPickerView()
                .environmentObject(vm)
        }
        .sheet(isPresented: $showingMorphSheet) {
            MorphSheetView()
                .environmentObject(vm)
        }
        .modifier(SnapshotToastModifier(
            toast: $snapshotToast,
            isError: $snapshotToastIsError,
            toastTask: $snapshotToastTask
        ))
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
                // "?" button — re-opens the first-launch onboarding tour for
                // returning users who want a refresher or want to show a
                // friend what the app does.
                Button {
                    NotificationCenter.default.post(name: .showOnboarding, object: nil)
                } label: {
                    Image(systemName: "questionmark.circle")
                        .font(.system(size: 16, weight: .semibold))
                        .frame(width: 34, height: 34)
                        .background(Circle().fill(Color.white.opacity(0.10)))
                        .foregroundStyle(.white)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Show onboarding tour")
                Button {
                    captureSnapshot()
                } label: {
                    Image(systemName: "camera.fill")
                        .font(.system(size: 15, weight: .semibold))
                        .frame(width: 34, height: 34)
                        .background(Circle().fill(Color.white.opacity(0.10)))
                        .foregroundStyle(.white)
                }
                .buttonStyle(.plain)
                Button {
                    vm.showSpectrum.toggle()
                } label: {
                    Image(systemName: "chart.bar.fill")
                        .font(.system(size: 16, weight: .semibold))
                        .frame(width: 34, height: 34)
                        .background(Circle().fill(vm.showSpectrum
                            ? Color(red: 0.55, green: 0.76, blue: 1.0).opacity(0.30)
                            : Color.white.opacity(0.10)))
                        .foregroundStyle(.white)
                }
                .buttonStyle(.plain)
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
            // Horizontal scroll wrapper — without this on iPhone portrait
            // (width ~390pt) the JOURNEY + MORPH pills get clipped past the
            // right edge. iPad still shows them all without needing to
            // scroll because the canvas is wide enough.
            ScrollView(.horizontal, showsIndicators: false) {
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

                    Button { showingMorphSheet = true } label: { morphPill }
                        .buttonStyle(.plain)
                }
                .padding(.trailing, 4)
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

    /// Pill that opens the morph sheet. Tinted purple when a morph is
    /// active (both From and To picked); shows the current percentage.
    private var morphPill: some View {
        let active = (vm.morphFromName != nil) && (vm.morphToName != nil)
        let running = vm.morphIsRunning
        let value: String
        if active {
            let pct = Int((vm.morphAmount * 100).rounded())
            value = running ? "▶ \(pct)%" : "\(pct)%"
        } else {
            value = "Off"
        }
        let purple = Color(red: 0.81, green: 0.71, blue: 0.92)
        return HStack(spacing: 6) {
            Image(systemName: running
                  ? "arrow.left.arrow.right.circle.fill"
                  : (active ? "arrow.left.arrow.right.circle.fill" : "arrow.left.arrow.right.circle"))
                .font(.caption.weight(.semibold))
            VStack(alignment: .leading, spacing: 0) {
                Text("MORPH")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(active ? purple : .white.opacity(0.6))
                Text(value)
                    .font(.system(.footnote, design: .rounded).weight(.semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(
            Capsule().fill(active ? purple.opacity(0.20) : Color.white.opacity(0.10))
        )
        .overlay(
            Capsule().stroke(active ? purple.opacity(0.40) : .clear, lineWidth: 1)
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
            // Pill row in a horizontal scroll. NOTE: do NOT use
            // .scrollClipDisabled() here — it disables clipping on BOTH
            // axes, which lets the rightmost pill overflow past the
            // scroll bounds and overlap the icon buttons on the right
            // edge of the header. SwiftUI Menus open in the system
            // overlay (not the parent view), so we don't need
            // scroll-clip-disabled for that anyway.
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

                    Button { showingMorphSheet = true } label: { morphPill }
                        .buttonStyle(.plain)
                }
                .padding(.trailing, 4)
            }
            // Lower layout priority than the icon group → ScrollView only
            // takes the leftover width after the icons claim their fixed
            // space, so pills can never expand into the icon area.
            .layoutPriority(0)

            // Same icon order as the portrait header so the structure stays
            // consistent across orientations: camera (snapshot) → spectrum
            // toggle → Chladni toggle. Grouped in their own HStack with a
            // higher layoutPriority so they always render fully on the
            // right edge, never crowded by the scrolling pill row.
            HStack(spacing: 6) {
            // Compact "?" — re-opens onboarding tour. Same notification
            // post pattern as the portrait header, just smaller glyph.
            Button {
                NotificationCenter.default.post(name: .showOnboarding, object: nil)
            } label: {
                Image(systemName: "questionmark.circle")
                    .font(.system(size: 12, weight: .semibold))
                    .frame(width: 28, height: 28)
                    .background(Circle().fill(Color.white.opacity(0.10)))
                    .foregroundStyle(.white)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Show onboarding tour")
            Button { captureSnapshot() } label: {
                Image(systemName: "camera.fill")
                    .font(.system(size: 12, weight: .semibold))
                    .frame(width: 28, height: 28)
                    .background(Circle().fill(Color.white.opacity(0.10)))
                    .foregroundStyle(.white)
            }
            .buttonStyle(.plain)
            Button { vm.showSpectrum.toggle() } label: {
                Image(systemName: "chart.bar.fill")
                    .font(.system(size: 12, weight: .semibold))
                    .frame(width: 28, height: 28)
                    .background(Circle().fill(vm.showSpectrum
                        ? Color(red: 0.55, green: 0.76, blue: 1.0).opacity(0.30)
                        : Color.white.opacity(0.10)))
                    .foregroundStyle(.white)
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
            .layoutPriority(1)  // icons reserve their fixed width first
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

    // MARK: - Snapshot

    /// Render the current Chladni state to an image and save it to the
    /// user's Photos library. Shows a 2-second toast with success/failure.
    @MainActor
    private func captureSnapshot() {
        // Wire one-shot notification observers if not already attached.
        attachSnapshotObservers()
        SnapshotHelper.captureAndSave(vm: vm)
    }

    private func attachSnapshotObservers() {
        // Idempotent — re-adding the same observer name/object/queue creates
        // a duplicate, so guard via a stored token. We use a class-side
        // attached-flag pattern via NotificationCenter's auto-deduping:
        // since the closures change identity on each render, we instead
        // post into a single sink hooked at the parent level via .onReceive
        // below. The actual wiring happens in the .onReceive modifier in
        // body — see chained `.modifier(...)` below.
    }
}

/// View-modifier that hangs the notification observers off `body` so SwiftUI
/// manages their lifecycle, and renders the toast banner on top of the
/// controls layer. Kept separate so the body of `ControlsOverlay` stays
/// readable.
private struct SnapshotToastModifier: ViewModifier {
    @Binding var toast: String?
    @Binding var isError: Bool
    @Binding var toastTask: Task<Void, Never>?

    private let savedPub  = NotificationCenter.default.publisher(for: .cymaticSnapshotSaved)
    private let failedPub = NotificationCenter.default.publisher(for: .cymaticSnapshotFailed)

    func body(content: Content) -> some View {
        content
            .overlay(alignment: .top) {
                if let toast {
                    Text(toast)
                        .font(.footnote.weight(.semibold))
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .background(
                            Capsule().fill(isError
                                ? Color(red: 0.65, green: 0.20, blue: 0.20).opacity(0.92)
                                : Color.black.opacity(0.78))
                        )
                        .overlay(
                            Capsule().stroke(Color.white.opacity(0.30), lineWidth: 1)
                        )
                        .foregroundStyle(.white)
                        .padding(.top, 14)
                        .transition(.move(edge: .top).combined(with: .opacity))
                }
            }
            .onReceive(savedPub) { _ in
                show(message: "Saved to Photos", error: false)
            }
            .onReceive(failedPub) { note in
                let reason = (note.userInfo?["reason"] as? String) ?? "Save failed"
                show(message: reason, error: true)
            }
    }

    private func show(message: String, error: Bool) {
        toastTask?.cancel()
        withAnimation(.easeOut(duration: 0.20)) {
            isError = error
            toast = message
        }
        toastTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            guard !Task.isCancelled else { return }
            withAnimation(.easeOut(duration: 0.30)) { toast = nil }
        }
    }
}
