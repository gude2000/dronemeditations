import SwiftUI

/// Slim bottom strip with 4 mini-osc controls (freq slider + S + M) that
/// stays visible when the main controls overlay is hidden. Mirrors the
/// web pop-out's `#popup-controls` strip so the Chladni-only view is
/// usable without bringing back the full controls panel.
struct ChladniMiniControls: View {
    @EnvironmentObject var vm: DroneViewModel

    private let freqMin: Double = 20
    private let freqMax: Double = 2000

    var body: some View {
        HStack(spacing: 6) {
            ForEach(Array(vm.oscillators.enumerated()), id: \.element.id) { i, osc in
                MiniOscRow(index: i, osc: osc, freqMin: freqMin, freqMax: freqMax)
                    .environmentObject(vm)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .padding(.bottom, 4)
        .background(
            LinearGradient(
                colors: [.black.opacity(0.0), .black.opacity(0.55), .black.opacity(0.75)],
                startPoint: .top, endPoint: .bottom
            )
            .ignoresSafeArea(edges: .bottom)
        )
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
        HStack(spacing: 6) {
            Text("OSC \(index + 1)")
                .font(.system(size: 9, weight: .heavy))
                .foregroundStyle(.white.opacity(0.55))
                .frame(width: 32, alignment: .leading)

            VStack(alignment: .leading, spacing: 2) {
                Text(String(format: "%.2f Hz", osc.frequencyHz))
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.85))
                Slider(
                    value: Binding(
                        get: { freqT },
                        set: { vm.setFrequency(freqFromT($0), for: index) }
                    ),
                    in: 0...1
                )
                .tint(.white)
                .controlSize(.mini)
            }

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
        .padding(.vertical, 6)
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
