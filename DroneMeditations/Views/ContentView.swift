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

            // Tap layer (always present, beneath the controls so the controls'
            // buttons win). Hosts both the tap-to-toggle-controls gesture and
            // pinch-to-zoom the Chladni plate, simultaneously so neither blocks
            // the other.
            Color.clear
                .contentShape(Rectangle())
                .gesture(
                    SimultaneousGesture(
                        TapGesture().onEnded {
                            withAnimation(.easeInOut(duration: 0.22)) {
                                vm.showControls.toggle()
                            }
                        },
                        MagnificationGesture()
                            .updating($pinchScale) { value, state, _ in
                                state = value
                            }
                            .onEnded { value in
                                let raw = chladniZoom * Double(value)
                                chladniZoom = min(zoomMax, max(zoomMin, raw))
                            }
                    )
                )
                .ignoresSafeArea()

            if vm.showControls {
                ControlsOverlay()
                    .environmentObject(vm)
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
            } else {
                tapHint
            }
        }
        .background(Color.black.ignoresSafeArea())
        .statusBarHidden(true)
    }

    private var tapHint: some View {
        VStack {
            Spacer()
            Text("Tap to show controls")
                .font(.footnote)
                .foregroundStyle(.white.opacity(0.55))
                .padding(.bottom, 28)
        }
    }
}

#Preview {
    ContentView()
        .environmentObject(DroneViewModel())
}
