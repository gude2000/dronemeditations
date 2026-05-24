import SwiftUI

struct ContentView: View {
    @EnvironmentObject var vm: DroneViewModel

    var body: some View {
        ZStack {
            BlobBackground()
                .environmentObject(vm)

            if vm.showChladni {
                ChladniView()
                    .environmentObject(vm)
            }

            // Tap layer (always present, beneath the controls so the controls' buttons win).
            Color.clear
                .contentShape(Rectangle())
                .onTapGesture {
                    withAnimation(.easeInOut(duration: 0.22)) {
                        vm.showControls.toggle()
                    }
                }
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
