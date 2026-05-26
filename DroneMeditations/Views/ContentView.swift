import SwiftUI

struct ContentView: View {
    @EnvironmentObject var vm: DroneViewModel

    /// Committed Chladni zoom (1.0 = plate fills viewport). Persisted across
    /// launches; updated when a pinch gesture ends.
    @AppStorage("chladniZoom") private var chladniZoom: Double = 1.0
    /// Transient pinch magnification during an in-flight gesture; resets to
    /// 1.0 between gestures via @GestureState.
    @GestureState private var pinchScale: CGFloat = 1.0

    private let zoomMin: Double = 0.25
    private let zoomMax: Double = 4.0

    /// Effective zoom shown on screen — committed × in-flight pinch delta.
    private var liveZoom: Double {
        let raw = chladniZoom * Double(pinchScale)
        return min(zoomMax, max(zoomMin, raw))
    }

    var body: some View {
        ZStack {
            BlobBackground()
                .environmentObject(vm)

            if vm.showChladni {
                ChladniView(zoom: liveZoom)
                    .environmentObject(vm)
            }
            if vm.showSpectrum {
                SpectrumView(tap: vm.spectrumTap)
                    .environmentObject(vm)
            }

            // Tap layer (always present, beneath the controls so the controls'
            // buttons win). Tap toggles the main controls; a separately-attached
            // simultaneous magnification gesture handles pinch-to-zoom. Using
            // the .simultaneousGesture *modifier* (rather than the
            // SimultaneousGesture type composed inside .gesture) is the
            // reliable SwiftUI pattern for tap+pinch on the same view.
            Color.clear
                .contentShape(Rectangle())
                .onTapGesture {
                    withAnimation(.easeInOut(duration: 0.22)) {
                        vm.showControls.toggle()
                    }
                }
                .simultaneousGesture(
                    MagnificationGesture()
                        .updating($pinchScale) { value, state, _ in
                            state = value
                        }
                        .onEnded { value in
                            let raw = chladniZoom * Double(value)
                            chladniZoom = min(zoomMax, max(zoomMin, raw))
                        }
                )
                .ignoresSafeArea()

            if vm.performanceMode {
                // Cymatics-only Performance — everything except the pattern
                // and a tiny Exit affordance is hidden.
                performanceExit
            } else if vm.showControls {
                ControlsOverlay()
                    .environmentObject(vm)
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
            } else {
                // When the full controls panel is hidden, show a slim bottom
                // strip (matches the web pop-out's #popup-controls) so the
                // user can still adjust freq / Solo / Mute while watching
                // the Chladni full-screen.
                VStack(spacing: 0) {
                    Spacer()
                    tapHint
                    ChladniMiniControls()
                        .environmentObject(vm)
                }
                .transition(.opacity)
            }

            // Copyright + Manual link is now inlined inside ControlsOverlay
            // (below TransportView) and ChladniMiniControls (below the
            // mini-osc rows). That keeps it flush against whatever chrome
            // is at the bottom — no more floating overlay that drifted on
            // top of the transport or mini-bar in different orientations.
        }
        .background(Color.black.ignoresSafeArea())
        .statusBarHidden(true)
    }

    /// "Exit" pill in the top-left corner. Auto-dims after a few seconds
    /// so it doesn't intrude on the Performance view, but never fully
    /// disappears (kept at 0.45 opacity), AND a tap anywhere on the
    /// screen wakes it back to full brightness for another fade cycle.
    /// This avoids the previous bug where the button became effectively
    /// invisible and trapped the user in Performance mode.
    @State private var exitVisible: Bool = true
    @State private var exitFadeTask: Task<Void, Never>?

    private var performanceExit: some View {
        ZStack {
            // Wake-on-tap layer covering the whole screen. Doesn't block
            // the Exit button (it's stacked above), but catches taps
            // anywhere else on the Chladni so the user can always reveal
            // the Exit button by tapping the screen.
            Color.clear
                .contentShape(Rectangle())
                .onTapGesture { wakeExitButton() }
                .ignoresSafeArea()

            VStack {
                HStack {
                    Button {
                        exitPerformance()
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "xmark")
                                .font(.system(size: 11, weight: .bold))
                            Text("Exit")
                                .font(.system(size: 12, weight: .medium))
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 7)
                        .background(Capsule().fill(Color.black.opacity(0.60)))
                        .overlay(Capsule().stroke(Color.white.opacity(0.35), lineWidth: 1))
                        .foregroundStyle(.white)
                    }
                    .buttonStyle(.plain)
                    .opacity(exitVisible ? 1.0 : 0.45)
                    .padding(.leading, 12)
                    .padding(.top, 12)
                    Spacer()
                }
                Spacer()
            }
            .ignoresSafeArea(.keyboard)
        }
        .onAppear { wakeExitButton() }
        .onDisappear {
            exitFadeTask?.cancel()
            exitFadeTask = nil
            exitVisible = true
        }
    }

    /// Bring the Exit button to full opacity and (re)start the auto-dim
    /// timer. Any in-flight fade task is cancelled so successive taps
    /// keep it visible.
    private func wakeExitButton() {
        exitFadeTask?.cancel()
        withAnimation(.easeOut(duration: 0.18)) { exitVisible = true }
        exitFadeTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            guard !Task.isCancelled else { return }
            withAnimation(.easeOut(duration: 0.7)) { exitVisible = false }
        }
    }

    private func exitPerformance() {
        exitFadeTask?.cancel()
        withAnimation(.easeInOut(duration: 0.22)) {
            vm.performanceMode = false
            vm.showControls = true
        }
    }

    private var tapHint: some View {
        Text("Tap to show controls")
            .font(.footnote)
            .foregroundStyle(.white.opacity(0.55))
            .padding(.bottom, 10)
            .allowsHitTesting(false)
    }

}

#Preview {
    ContentView()
        .environmentObject(DroneViewModel())
}
