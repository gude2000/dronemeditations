import SwiftUI

/// Physically-calibrated Chladni renderer.
///
/// The frequency → pattern mapping is fit from 17 brusspup demo frames
/// (345 Hz → 6051 Hz) where each frame was visually identified as a (m,n)
/// mode pair on a thin square plate:
///
///   f(m, n) ≈ K_PLATE · (m² + n²),  K_PLATE = 18.6 ± 0.8 Hz
///
/// For each voice we pick the two adjacent eigenmode pairs that bracket the
/// live frequency and crossfade between them, so vibrato breathes smoothly
/// between physical modes instead of snapping or following an arbitrary
/// continuous-m curve.
///
/// brusspup's plate is center-driven (a small bolt in the middle), so every
/// real frame shows a tiny sand pile on the driver and a thin nodal ring at
/// small radius. Both are added unconditionally on top of the eigenmode field.
struct ChladniView: View {
    @EnvironmentObject var vm: DroneViewModel

    /// Optional zoom (1.0 = plate fills viewport; >1 zooms in on center;
    /// <1 shrinks the plate inside the viewport).
    var zoom: Double = 1.0

    /// Resolution of the sampled grid (lower = faster, more abstract; higher = sharper lines).
    /// 140 gives dense classic Chladni geometry on iPhone without dropping frames.
    private let grid: Int = 140

    var body: some View {
        // 24 fps so vibrato (pitch-LFO mod) is visibly smooth in the pattern.
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
        // Build the active mode list: up to 4 voices × 2 crossfading modes each.
        struct ActiveMode {
            let m: Int
            let n: Int
            let weight: Double
            let hue: Double
        }
        var modes: [ActiveMode] = []
        for (i, osc) in vm.oscillators.enumerated() {
            guard !osc.isMuted else { continue }
            let liveFreq = vm.audioEngine.voices.indices.contains(i)
                ? vm.audioEngine.voices[i].liveFrequencyHz
                : osc.frequencyHz
            let pair = Self.modePairForFreq(liveFreq)
            let hue = frequencyHueFromHz(liveFreq)
            for mode in pair where mode.weight > 0.001 {
                modes.append(ActiveMode(
                    m: mode.m, n: mode.n,
                    weight: mode.weight * osc.amplitude,
                    hue: hue
                ))
            }
        }

        let cell = CGSize(width: size.width / CGFloat(grid),
                          height: size.height / CGFloat(grid))

        let z = max(0.01, zoom)
        for j in 0..<grid {
            for i in 0..<grid {
                let screenX = (Double(i) + 0.5) / Double(grid)
                let screenY = (Double(j) + 0.5) / Double(grid)
                // Inverse zoom transform around plate center. Cells whose
                // sampled plate position falls outside [0,1]² are off the
                // plate and skipped (so the plate visibly shrinks at z<1).
                let x = (screenX - 0.5) / z + 0.5
                let y = (screenY - 0.5) / z + 0.5
                guard x >= 0, x <= 1, y >= 0, y <= 1 else { continue }

                var field = 0.0
                var hueAccum = 0.0
                var weightAccum = 0.0
                for v in modes {
                    let mPi = Double(v.m) * .pi
                    let nPi = Double(v.n) * .pi
                    // Antisymmetric — calibration table only has m < n.
                    let term = 0.5 * (cos(mPi * x) * cos(nPi * y)
                                    - cos(nPi * x) * cos(mPi * y))
                    field += term * v.weight
                    hueAccum += v.hue * v.weight
                    weightAccum += v.weight
                }

                let mag = abs(field)
                var nodeStrength = max(0.0, 1.0 - mag * 6.0)

                // Center-driver bolt: ever-present small sand pile + thin
                // nodal ring at small radius. Visible in every brusspup frame.
                let dx = x - 0.5
                let dy = y - 0.5
                let rCenter = sqrt(dx * dx + dy * dy)
                let centerBlob = smoothstep(0.025, 0.015, rCenter)
                let centerRing = smoothstep(0.012, 0.0, abs(rCenter - 0.075))
                nodeStrength = max(nodeStrength,
                                   max(centerBlob * 0.55, centerRing * 0.75))

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

    // MARK: - Eigenmode calibration (empirical, antisymmetric basis)
    //
    // Merges visual identification from two reference videos: a small
    // free-edge plate (86–650 Hz) and brusspup's larger center-driven
    // plate (345–6051 Hz). All entries are antisymmetric (m, n) pairs
    // with m < n, so the antisymmetric Chladni formula never vanishes.

    private static let calibration: [(freq: Double, m: Int, n: Int)] = [
        // Bass region — small plate
        (  86, 1,  2),  ( 230, 2,  3),  ( 285, 1,  6),  ( 345, 2,  4),
        ( 460, 3,  4),  ( 575, 3,  5),  ( 650, 3,  5),
        // Mid–high — brusspup plate
        (1033, 4,  5),  (1820, 6,  7),  (2041, 7,  8),  (3240, 9, 10),
        (3835, 9, 11),  (3975, 9, 12),  (4049, 10, 11), (4129, 1, 15),
        (4173, 3, 15),  (4221, 7, 13),  (4280, 2, 15),  (4444, 4, 15),
        (4671, 5, 15),  (4840, 9, 13),  (5201, 10, 13), (5284, 11, 13),
        (5907, 12, 13), (6051, 12, 14),
    ]

    private static let kPlateBass: Double = 86.0 / 5.0  // (1,2) at 86 Hz

    /// Pick two (m, n) eigenmodes to render at the given frequency, with
    /// crossfade weights that sum to 1.
    private static func modePairForFreq(_ freq: Double) -> [(m: Int, n: Int, weight: Double)] {
        let f = max(0, freq)
        // Sub-bass: below the lowest measured point — extrapolate (1, n)
        // where n grows with frequency.
        if f <= calibration[0].freq {
            let target = f / kPlateBass
            let nFloat = sqrt(max(0, target - 1))
            let nLo = max(1, Int(floor(nFloat)))
            let nHi = nLo + 1
            let t = max(0, min(1, nFloat - Double(nLo)))
            return [(1, nLo, 1 - t), (1, nHi, t)]
        }
        // Above highest measured — pin.
        let lastIdx = calibration.count - 1
        if f >= calibration[lastIdx].freq {
            let last = calibration[lastIdx]
            return [(last.m, last.n, 1.0), (last.m, last.n, 0.0)]
        }
        // Between two measured: crossfade linearly in frequency.
        var lo = 0, hi = lastIdx
        while lo < hi - 1 {
            let mid = (lo + hi) >> 1
            if calibration[mid].freq <= f { lo = mid } else { hi = mid }
        }
        let a = calibration[lo], b = calibration[hi]
        let t = (f - a.freq) / (b.freq - a.freq)
        return [(a.m, a.n, 1 - t), (b.m, b.n, t)]
    }

    private func smoothstep(_ edge0: Double, _ edge1: Double, _ x: Double) -> Double {
        let t = max(0, min(1, (x - edge0) / (edge1 - edge0)))
        return t * t * (3 - 2 * t)
    }
}
