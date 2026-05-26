import SwiftUI

/// Slim bottom strip with 4 mini-osc controls (freq slider + S + M) that
/// stays visible when the main controls overlay is hidden. Mirrors the
/// web pop-out's `#popup-controls` strip so the Chladni-only view is
/// usable without bringing back the full controls panel.
struct ChladniMiniControls: View {
    @EnvironmentObject var vm: DroneViewModel

    private let freqMin: Double = 20
    private let freqMax: Double = 2000

    // Match the controls overlay: widen the mini-bar on iPad so the four
    // freq sliders breathe across more of the canvas instead of huddling
    // in a 900pt strip with ~1.5" of unused screen on each side.
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    private var stripMaxWidth: CGFloat {
        horizontalSizeClass == .regular ? 1200 : 900
    }

    var body: some View {
        // 2x2 grid: left column stacks OSC 1 over OSC 2, right column stacks
        // OSC 3 over OSC 4. Each row gets half the screen width, so the
        // freq slider has enough throw to be usable. Two short stacked
        // rows fit the same vertical space the old 4-across single tall row
        // used while doubling slider precision.
        let count = vm.oscillators.count
        // Outer ZStack lets the gradient background span the full iPad width
        // while the actual osc rows stay capped at 900pt and centered.
        ZStack {
            // Full-width gradient + safe-area extension.
            LinearGradient(
                colors: [.black.opacity(0.0), .black.opacity(0.55), .black.opacity(0.75)],
                startPoint: .top, endPoint: .bottom
            )
            .ignoresSafeArea(edges: .bottom)

            // Mini-osc rows on top, copyright + Manual link directly below
            // them. Stacking them in the same VStack means the copyright row
            // sits flush against the bottom of the mini-osc bar with no gap
            // — and never overlaps the bar, the way the old floating
            // overlay did.
            VStack(spacing: 2) {
                HStack(spacing: 8) {
                    if count > 0 {
                        VStack(spacing: 4) {
                            ForEach(0..<min(2, count), id: \.self) { i in
                                MiniOscRow(index: i, osc: vm.oscillators[i],
                                           freqMin: freqMin, freqMax: freqMax)
                                    .environmentObject(vm)
                            }
                        }
                    }
                    if count > 2 {
                        VStack(spacing: 4) {
                            ForEach(2..<min(4, count), id: \.self) { i in
                                MiniOscRow(index: i, osc: vm.oscillators[i],
                                           freqMin: freqMin, freqMax: freqMax)
                                    .environmentObject(vm)
                            }
                        }
                    }
                }
                .padding(.horizontal, 10)
                .padding(.top, 6)

                CopyrightStrip()
                    .padding(.bottom, 4)
            }
            // iPhone: 900pt cap is a no-op (screens are < 900pt wide).
            // iPad: 1200pt fills portrait (1024pt — clamped) and leaves only
            // modest gutters in landscape (1366pt), matching the controls
            // overlay's wider panel cap.
            .frame(maxWidth: stripMaxWidth)
        }
        .fixedSize(horizontal: false, vertical: true)
        // Capture taps that hit the strip background (between controls) so they
        // don't bubble through to the tap-layer underneath and toggle controls.
        .contentShape(Rectangle())
        .onTapGesture {}
    }
}

private struct MiniOscRow: View {
    @EnvironmentObject var vm: DroneViewModel
    let index: Int
    let osc: OscillatorState
    let freqMin: Double
    let freqMax: Double

    private var anySoloed: Bool { vm.oscillators.contains { $0.isSoloed } }
    private var silenced: Bool { (anySoloed && !osc.isSoloed) || osc.isMuted }

    private var freqT: Double {
        let logF = log2(max(freqMin, osc.frequencyHz))
        let lo = log2(freqMin), hi = log2(freqMax)
        return (logF - lo) / (hi - lo)
    }
    private func freqFromT(_ t: Double) -> Double {
        let lo = log2(freqMin), hi = log2(freqMax)
        return pow(2.0, lo + t * (hi - lo))
    }

    var body: some View {
        // Single linear row: label · freq slider (taking all available width)
        // · S · M. Frequency readout is overlaid above the slider thumb so it
        // doesn't steal horizontal space.
        HStack(spacing: 6) {
            VStack(alignment: .leading, spacing: 0) {
                Text("OSC \(index + 1)")
                    .font(.system(size: 8, weight: .heavy))
                    .foregroundStyle(.white.opacity(0.55))
                Text(String(format: "%.0f Hz", osc.frequencyHz))
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.85))
            }
            .frame(width: 44, alignment: .leading)

            Slider(
                value: Binding(
                    get: { freqT },
                    set: { vm.setFrequency(freqFromT($0), for: index) }
                ),
                in: 0...1
            )
            .tint(.white)
            .controlSize(.mini)

            Button {
                vm.toggleSolo(index)
            } label: {
                Text("S")
                    .font(.system(size: 10, weight: .heavy))
                    .frame(width: 22, height: 22)
                    .background(osc.isSoloed ? Color(red: 0.97, green: 0.79, blue: 0.28) : Color.white.opacity(0.10))
                    .foregroundStyle(osc.isSoloed ? Color.black : Color.white)
                    .clipShape(Circle())
            }
            .buttonStyle(.plain)

            Button {
                vm.toggleMute(index)
            } label: {
                Text("M")
                    .font(.system(size: 10, weight: .heavy))
                    .frame(width: 22, height: 22)
                    .background(osc.isMuted ? Color(red: 0.88, green: 0.32, blue: 0.29) : Color.white.opacity(0.10))
                    .foregroundStyle(.white)
                    .clipShape(Circle())
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.white.opacity(0.06))
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(Color.white.opacity(0.08), lineWidth: 1)
                )
        )
        .frame(maxWidth: .infinity)
        .opacity(silenced ? 0.5 : 1.0)
    }
}
