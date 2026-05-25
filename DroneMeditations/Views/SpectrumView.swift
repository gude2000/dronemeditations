import SwiftUI

/// Real-time FFT spectrum bars sourced from `vm.spectrumTap.bins`.
/// Log-frequency horizontal axis (20 Hz → 16 kHz), magnitude on Y.
struct SpectrumView: View {
    @EnvironmentObject var vm: DroneViewModel
    @ObservedObject var tap: SpectrumTap

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { _ in
            Canvas { context, size in
                draw(into: context, size: size)
            }
            .blendMode(.screen)
            .opacity(0.78)
            .allowsHitTesting(false)
            .ignoresSafeArea()
        }
    }

    private func draw(into context: GraphicsContext, size: CGSize) {
        let bins = tap.bins
        if bins.isEmpty { return }
        let sr = vm.audioEngine.sampleRate
        let nyquist = sr / 2.0

        let minHz = 20.0
        let maxHz = 16000.0
        let logLo = log2(minHz), logHi = log2(maxHz)

        let barW: CGFloat = 4
        let cols = max(1, Int(size.width / barW))
        for i in 0..<cols {
            let t = Double(i) / Double(cols - 1)
            let hz = pow(2.0, logLo + t * (logHi - logLo))
            let binIdx = min(bins.count - 1, Int((hz / nyquist) * Double(bins.count)))
            let level = Double(bins[binIdx])
            if level < 0.02 { continue }
            let barH = max(2, level * size.height * 0.7)
            let y = size.height - barH
            // Same warm-low / cool-high hue ramp as Chladni & web spectrum.
            let hue = 0.05 + 0.6 * t
            let color = Color(hue: hue, saturation: 0.7, brightness: 0.85,
                              opacity: 0.35 + 0.5 * level)
            let rect = CGRect(x: CGFloat(i) * barW, y: y,
                              width: barW - 1, height: barH)
            context.fill(Path(rect), with: .color(color))
        }
    }
}
