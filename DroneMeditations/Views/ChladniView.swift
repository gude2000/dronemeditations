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
    /// 140 gives dense classic Chladni geometry on iPhone without dropping frames.
    private let grid: Int = 140

    var body: some View {
        // 24 fps so vibrato (pitch-LFO mod) is visibly smooth in the pattern.
        // Heavier than 12 fps but still well within iPhone budget at 140-grid.
        TimelineView(.animation(minimumInterval: 1.0 / 24.0)) { _ in
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
        // Read live (slewed + pitch-LFO-modulated) frequency from the engine
        // so the nodal pattern morphs in real time as vibrato plays. Falls
        // back to the UI-state base freq if the engine voice index doesn't
        // line up (defensive).
        let voiceN = [4, 6, 9, 11]
        var modes: [(m: Int, n: Int, weight: Double, hue: Double)] = []
        for (i, osc) in vm.oscillators.enumerated() {
            guard !osc.isMuted else { continue }
            let liveFreq = vm.audioEngine.voices.indices.contains(i)
                ? vm.audioEngine.voices[i].liveFrequencyHz
                : osc.frequencyHz
            let logF = log2(max(liveFreq, 20.0))
            let lo = log2(20.0), hi = log2(2000.0)
            let t = (logF - lo) / (hi - lo)
            let m = max(3, Int((3.0 + t * 11.0).rounded()))
            let n = voiceN[osc.id % voiceN.count]
            // Hue follows live freq too so vibrato shifts color subtly.
            let liveHue = frequencyHueFromHz(liveFreq)
            modes.append((m, n, osc.amplitude, liveHue))
        }
        guard !modes.isEmpty else { return }

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

    /// Same hue math as OscillatorState.hue but takes a raw Hz value so we
    /// can color by the live pitch-LFO-modulated frequency.
    private func frequencyHueFromHz(_ hz: Double) -> Double {
        let logF = log2(max(hz, 20.0))
        let lo = log2(20.0)
        let hi = log2(2000.0)
        let t = (logF - lo) / (hi - lo)
        return 0.05 + (0.6 * t)
    }
}
