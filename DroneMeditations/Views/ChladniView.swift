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

    /// v1 sand-grain simulation. 1500 particles attracted to nodal
    /// lines, with damping + Brownian jitter, drawn over the Chladni
    /// field — same idea as the web pop-out, halved particle count so
    /// the main thread keeps headroom for the audio render thread.
    /// Stored as a reference type so per-frame mutation doesn't
    /// trigger Swift's value-type COW.
    @StateObject private var sand = SandSimulation(particleCount: 1500)

    var body: some View {
        // ~30 fps so vibrato (pitch-LFO modulation) breathes smoothly through
        // the pattern. The Chladni FIELD is now a GPU fragment shader
        // (Chladni.metal, per-pixel + sharp) instead of a CPU grid of filled
        // cells; the sand grains stay on a CPU Canvas overlaid on top (a few
        // thousand dots is cheap).
        TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { _ in
            let modes = activeModes()
            let packed = packModes(modes)
            GeometryReader { geo in
                ZStack {
                    Rectangle()
                        .fill(.black)
                        .colorEffect(ShaderLibrary.chladniField(
                            .float2(Float(geo.size.width), Float(geo.size.height)),
                            .float(Float(max(0.01, zoom))),
                            .float(Float(packed.count)),
                            .floatArray(packed.ms),
                            .floatArray(packed.ns),
                            .floatArray(packed.ws),
                            .floatArray(packed.hues)
                        ))
                    Canvas { context, size in
                        sand.stepAndDraw(in: context, size: size, modes: modes, zoom: zoom)
                    }
                }
            }
            .blendMode(.plusLighter)
            .opacity(0.55)
            .allowsHitTesting(false)
            .ignoresSafeArea()
        }
    }

    /// Build the active mode list: up to 4 voices × 2 crossfading eigenmode
    /// pairs each. Shared by the GPU field shader and the sand simulation.
    private func activeModes() -> [ChladniActiveMode] {
        var modes: [ChladniActiveMode] = []
        for (i, osc) in vm.oscillators.enumerated() {
            guard !osc.isMuted else { continue }
            let liveFreq = vm.audioEngine.voices.indices.contains(i)
                ? vm.audioEngine.voices[i].liveFrequencyHz
                : osc.frequencyHz
            let pair = Self.modePairForFreq(liveFreq)
            let hue = frequencyHueFromHz(liveFreq)
            for mode in pair where mode.weight > 0.001 {
                modes.append(ChladniActiveMode(
                    m: mode.m, n: mode.n,
                    weight: mode.weight * osc.amplitude,
                    hue: hue
                ))
            }
        }
        return modes
    }

    /// Pack up to 8 modes into parallel Float arrays for the fragment shader,
    /// padded to 8 so the shader's fixed 0..<8 loop never reads past the end.
    private func packModes(_ modes: [ChladniActiveMode])
        -> (ms: [Float], ns: [Float], ws: [Float], hues: [Float], count: Int) {
        let capped = modes.prefix(8)
        var ms = [Float](repeating: 0, count: 8)
        var ns = [Float](repeating: 0, count: 8)
        var ws = [Float](repeating: 0, count: 8)
        var hues = [Float](repeating: 0, count: 8)
        for (i, mode) in capped.enumerated() {
            ms[i] = Float(mode.m)
            ns[i] = Float(mode.n)
            ws[i] = Float(mode.weight)
            hues[i] = Float(mode.hue)
        }
        return (ms, ns, ws, hues, capped.count)
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

}

// MARK: - Sand particle simulation (v1)

/// Each frame's active Chladni modes — shared between the field
/// renderer in ChladniView and the sand simulation below so the
/// grains pile up on the same nodal lines the user sees in the
/// pattern.
struct ChladniActiveMode {
    let m: Int
    let n: Int
    let weight: Double
    let hue: Double
}

/// 1500-particle simulation attracted to wherever the Chladni field
/// crosses zero (the nodal lines). Reference type so per-frame
/// mutation doesn't trigger Swift's value-type COW. SoA layout
/// (separate x / y / vx / vy arrays of Floats) for tighter cache
/// locality than [(x,y,vx,vy)] would give.
@MainActor
final class SandSimulation: ObservableObject {
    private let count: Int
    private var xs: [Float]
    private var ys: [Float]
    private var vxs: [Float]
    private var vys: [Float]

    init(particleCount: Int) {
        self.count = particleCount
        self.xs = (0..<particleCount).map { _ in Float.random(in: 0..<1) }
        self.ys = (0..<particleCount).map { _ in Float.random(in: 0..<1) }
        self.vxs = [Float](repeating: 0, count: particleCount)
        self.vys = [Float](repeating: 0, count: particleCount)
    }

    /// One-call step + draw. Updates particle positions then renders
    /// them as small warm-white rects on top of the Chladni field.
    /// Operates in plate coords [0, 1] internally; only the draw
    /// phase applies the zoom transform so grains visibly ride the
    /// same magnification as the pattern.
    func stepAndDraw(in context: GraphicsContext,
                     size: CGSize,
                     modes: [ChladniActiveMode],
                     zoom: Double) {
        // No modes → nothing to attract toward, but keep drawing the
        // existing particles so they don't pop off-screen when the
        // pattern is empty for a beat. Their velocities damp to zero
        // and they sit still until a new note arrives.
        let eps: Float = 0.004
        let attraction: Float = 0.0010
        let damping: Float = 0.87
        let jitter: Float = 0.0006

        for i in 0..<count {
            var x = xs[i]
            var y = ys[i]
            var vx = vxs[i]
            var vy = vys[i]

            if !modes.isEmpty {
                let f  = Self.field(Double(x),       Double(y),       modes: modes)
                let fx = Self.field(Double(x) + Double(eps), Double(y),       modes: modes)
                let fy = Self.field(Double(x),       Double(y) + Double(eps), modes: modes)
                let fdx = Float((fx - f) / Double(eps))
                let fdy = Float((fy - f) / Double(eps))
                let s: Float = f > 0 ? 1 : -1
                vx -= fdx * s * attraction
                vy -= fdy * s * attraction
            }
            vx *= damping
            vy *= damping
            vx += (Float.random(in: 0..<1) - 0.5) * jitter
            vy += (Float.random(in: 0..<1) - 0.5) * jitter
            x += vx
            y += vy
            if x < 0 { x += 1 } else if x > 1 { x -= 1 }
            if y < 0 { y += 1 } else if y > 1 { y -= 1 }

            xs[i]  = x
            ys[i]  = y
            vxs[i] = vx
            vys[i] = vy
        }

        // Draw all particles. Pre-build one CGRect-relative path and
        // fill it per grain — SwiftUI's Canvas is happy with thousands
        // of small fills at 24 fps on modern iPhones.
        let z = max(0.01, zoom)
        let sizePx: CGFloat = max(0.7, 1.4 * sqrt(CGFloat(z)))
        let grainColor = Color(red: 1.0, green: 0.94, blue: 0.84, opacity: 0.85)
        for i in 0..<count {
            // Apply the same zoom transform the WebGL shader uses:
            //   screen = (plate - 0.5) * zoom + 0.5
            // Particles outside [0, 1] in screen coords are off-canvas;
            // skip them so we don't overdraw the screen margins.
            let sx = (Double(xs[i]) - 0.5) * z + 0.5
            let sy = (Double(ys[i]) - 0.5) * z + 0.5
            guard sx >= 0, sx <= 1, sy >= 0, sy <= 1 else { continue }
            let rect = CGRect(
                x: sx * Double(size.width) - Double(sizePx) * 0.5,
                y: sy * Double(size.height) - Double(sizePx) * 0.5,
                width: Double(sizePx), height: Double(sizePx)
            )
            context.fill(Path(rect), with: .color(grainColor))
        }
    }

    /// CPU-side Chladni field evaluation. Same antisymmetric formula
    /// as the renderer's per-cell math, called per particle for the
    /// gradient finite-diff that pulls grains toward nodal lines.
    private static func field(_ x: Double, _ y: Double,
                              modes: [ChladniActiveMode]) -> Double {
        var total = 0.0
        for m in modes {
            let mPi = Double(m.m) * .pi
            let nPi = Double(m.n) * .pi
            let term = 0.5 * (cos(mPi * x) * cos(nPi * y)
                            - cos(nPi * x) * cos(mPi * y))
            total += term * m.weight
        }
        return total
    }
}
