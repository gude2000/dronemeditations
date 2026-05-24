import SwiftUI

/// A real-time Chladni-style nodal pattern derived from the 4 active frequencies.
///
/// True cymatics depend on the geometry of a vibrating plate / liquid, so the closest
/// faithful visual is a sum of standing-wave modes. We pick mode numbers (m, n) per voice
/// from each frequency (mapped log-spaced into 1..6) and render where the absolute value
/// of the summed Chladni field is small — those are the "nodal lines" where sand collects.
struct ChladniView: View {
    @EnvironmentObject var vm: DroneViewModel

    /// Resolution of the sampled grid (lower = faster, more abstract; higher = sharper lines).
    /// 112 gives classic Chladni geometry on iPhone without the SwiftUI Canvas
    /// dropping frames.
    private let grid: Int = 112

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 12.0)) { _ in
            Canvas { context, size in
                drawChladni(in: context, size: size)
            }
            .blendMode(.plusLighter)
            .opacity(0.55)
            .allowsHitTesting(false)
            .ignoresSafeArea()
        }
    }

    private func drawChladni(in context: GraphicsContext, size: CGSize) {
        let voices = vm.oscillators.filter { !$0.isMuted }
        guard !voices.isEmpty else { return }

        // Map each voice's frequency to integer mode numbers (m, n) in a small range.
        // Using log-spacing across 20..2000 Hz -> 1..6 mode index.
        let modes: [(m: Int, n: Int, weight: Double, hue: Double)] = voices.map { osc in
            let logF = log2(max(osc.frequencyHz, 20.0))
            let lo = log2(20.0), hi = log2(2000.0)
            let t = (logF - lo) / (hi - lo)
            // Mode range 2..10 (richer geometry than 1..6, especially at low freqs).
            let m = max(2, Int((2.0 + t * 8.0).rounded()))
            // Wider per-voice spread so each voice's pattern is distinguishable.
            let n = max(2, m + ((osc.id + 1) % 4) - 2)
            return (m, n, osc.amplitude, osc.hue)
        }

        let cell = CGSize(width: size.width / CGFloat(grid), height: size.height / CGFloat(grid))

        for j in 0..<grid {
            for i in 0..<grid {
                let x = (Double(i) + 0.5) / Double(grid)
                let y = (Double(j) + 0.5) / Double(grid)

                var field = 0.0
                var hueAccum = 0.0
                var weightAccum = 0.0
                for v in modes {
                    let mPi = Double(v.m) * .pi
                    let nPi = Double(v.n) * .pi
                    let term = cos(mPi * x) * cos(nPi * y) - cos(nPi * x) * cos(mPi * y)
                    field += term * v.weight
                    hueAccum += v.hue * v.weight
                    weightAccum += v.weight
                }
                let mag = abs(field)
                // Tighter threshold → thinner, sharper nodal lines.
                let nodeStrength = max(0.0, 1.0 - mag * 6.0)
                guard nodeStrength > 0.04 else { continue }

                let hue = weightAccum > 0 ? (hueAccum / weightAccum) : 0.5
                let color = Color(
                    hue: hue,
                    saturation: 0.25,
                    brightness: 0.95,
                    opacity: nodeStrength * 0.85
                )
                let rect = CGRect(
                    x: CGFloat(i) * cell.width,
                    y: CGFloat(j) * cell.height,
                    width: cell.width + 0.5,
                    height: cell.height + 0.5
                )
                context.fill(Path(rect), with: .color(color))
            }
        }
    }
}
