import SwiftUI

/// Four softly-colored organic blobs that drift around the screen. One per oscillator.
/// Each blob's color is derived from its oscillator's frequency band; its drift speed
/// scales mildly with frequency so high-pitched voices feel more active.
struct BlobBackground: View {
    @EnvironmentObject var vm: DroneViewModel

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { timeline in
            let t = timeline.date.timeIntervalSinceReferenceDate
            GeometryReader { proxy in
                ZStack {
                    LinearGradient(
                        colors: [Color(white: 0.02), Color(white: 0.08)],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                    .ignoresSafeArea()

                    ForEach(vm.oscillators) { osc in
                        BlobShape(t: t, osc: osc, size: proxy.size)
                    }
                }
            }
        }
        .ignoresSafeArea()
    }
}

private struct BlobShape: View {
    let t: TimeInterval
    let osc: OscillatorState
    let size: CGSize

    var body: some View {
        let drift = blobPath(t: t, osc: osc, size: size)
        let color = Color(hue: osc.hue, saturation: 0.55, brightness: 0.85, opacity: 0.32)
        Circle()
            .fill(
                RadialGradient(
                    colors: [color, color.opacity(0)],
                    center: .center,
                    startRadius: 1,
                    endRadius: drift.radius
                )
            )
            .frame(width: drift.radius * 2, height: drift.radius * 2)
            .position(x: drift.x, y: drift.y)
            .blendMode(.screen)
            .opacity(osc.isMuted ? 0.15 : 1.0)
    }

    private struct DriftPosition {
        var x: CGFloat
        var y: CGFloat
        var radius: CGFloat
    }

    /// Lissajous-like motion: each oscillator gets a unique phase offset and frequency mix.
    private func blobPath(t: TimeInterval, osc: OscillatorState, size: CGSize) -> DriftPosition {
        // Speed scales mildly with audio frequency (log) so the visual reflects the sound.
        let logF = log2(max(osc.frequencyHz, 20.0))
        let speedScale = 1.0 + (logF - log2(20.0)) / 12.0    // ~1.0 .. ~1.6

        // Per-voice phase offsets keep blobs from overlapping perfectly.
        let phaseA = Double(osc.id) * .pi * 0.5
        let phaseB = Double(osc.id) * .pi * 0.31

        // Two-frequency cross drift, slow enough to look like floating.
        let omegaX = 0.045 * speedScale
        let omegaY = 0.052 * speedScale

        let nx = (sin(omegaX * t + phaseA) + 0.6 * sin(0.13 * t + phaseB)) / 1.6
        let ny = (cos(omegaY * t + phaseB) + 0.6 * cos(0.17 * t + phaseA)) / 1.6

        let cx = (CGFloat(nx) * 0.5 + 0.5) * size.width
        let cy = (CGFloat(ny) * 0.5 + 0.5) * size.height
        let maxDim = max(size.width, size.height)
        let radiusFactor: CGFloat = 0.30 + 0.06 * CGFloat(osc.id % 3)
        let radius = maxDim * radiusFactor

        return DriftPosition(x: cx, y: cy, radius: radius)
    }
}
