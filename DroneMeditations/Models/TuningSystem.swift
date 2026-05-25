import Foundation

/// A tuning system maps a target interval (expressed in cents from a root) to a concrete
/// frequency ratio, by snapping the cents value to the system's grid. Frequencies are then
/// computed as `root * 2^(snappedCents / 1200)`.
enum TuningSystem: String, CaseIterable, Identifiable, Codable {
    case equal12         = "12-TET"        // Standard western equal temperament
    case equal24         = "24-TET"        // Quartertone equal temperament
    case equal72         = "72-TET"        // Microtonal (Maneri-Sims style)
    case wholeTone       = "Whole Tone"    // 6-TET (whole tone scale)
    case justIntonation  = "Just"          // 5-limit just intonation
    case pythagorean     = "Pythagorean"   // 3-limit Pythagorean
    case harrisonFreeJI  = "Harrison JI"   // Lou Harrison 7-tone JI (5 + 7 limit)
    case partch43        = "Partch 43"     // Harry Partch's 43-tone JI
    case carlosAlpha     = "Carlos α"      // 78.0 c/step non-octave equal
    case carlosBeta      = "Carlos β"      // 63.8 c/step non-octave equal
    case carlosGamma     = "Carlos γ"      // 35.1 c/step non-octave equal
    case phi             = "Phi (φ)"       // φ:1 pseudo-octave / 13 steps

    var id: String { rawValue }
    var displayName: String { rawValue }

    /// φ — the golden ratio.
    private static let phiRatio: Double = (1.0 + sqrt(5.0)) / 2.0
    /// One "phi-octave" expressed in cents.
    private static let phiOctaveCents: Double = log2(phiRatio) * 1200.0

    /// 5-limit just intonation, 12 named scale degrees within an octave (cents).
    private static let justCents: [Double] = [
        0,            // 1/1
        111.731,      // 16/15  (m2)
        203.910,      // 9/8    (M2)
        315.641,      // 6/5    (m3)
        386.314,      // 5/4    (M3)
        498.045,      // 4/3    (P4)
        582.512,      // 45/32  (TT — could also use 7/5 = 582.512 ≈)
        701.955,      // 3/2    (P5)
        813.686,      // 8/5    (m6)
        884.359,      // 5/3    (M6)
        1017.596,     // 9/5    (m7)
        1088.269      // 15/8   (M7)
    ]

    /// Pythagorean tuning, 12 scale degrees within an octave (cents).
    private static let pythagCents: [Double] = [
        0,            // 1/1
        113.685,      // 256/243
        203.910,      // 9/8
        294.135,      // 32/27
        407.820,      // 81/64
        498.045,      // 4/3
        611.730,      // 729/512
        701.955,      // 3/2
        792.180,      // 128/81
        905.865,      // 27/16
        996.090,      // 16/9
        1109.775      // 243/128
    ]

    /// Lou Harrison "Free-Style" JI — 7-tone scale he used across his
    /// gamelan + chamber works. Ratios: 1/1 9/8 5/4 4/3 3/2 5/3 7/4.
    private static let harrisonCents: [Double] = [
        0, 203.910, 386.314, 498.045, 701.955, 884.359, 968.826
    ]

    /// Harry Partch's 43-tone JI scale, cents from 1/1.
    private static let partch43Cents: [Double] = [
        0, 21.51, 53.27, 84.47, 111.73, 150.64, 165.00, 182.40, 203.91,
        231.17, 266.87, 294.13, 315.64, 347.41, 386.31, 417.51, 435.08,
        470.78, 498.04, 519.55, 551.32, 582.51, 617.49, 648.68, 680.45,
        701.96, 729.22, 764.92, 782.49, 813.69, 852.59, 884.36, 905.87,
        933.13, 968.83, 996.09, 1017.60, 1034.99, 1049.36, 1088.27,
        1115.53, 1146.73, 1178.49
    ]

    // Wendy Carlos non-octave equal-step tunings (cents per step).
    private static let carlosAlphaStep: Double = 78.0
    private static let carlosBetaStep:  Double = 63.8
    private static let carlosGammaStep: Double = 35.1

    /// Snap a target interval (cents from root) to this tuning's grid. Returns cents.
    func snap(cents: Double) -> Double {
        switch self {
        case .equal12:
            return Self.snapEqual(cents: cents, stepCents: 100.0)
        case .equal24:
            return Self.snapEqual(cents: cents, stepCents: 50.0)
        case .equal72:
            return Self.snapEqual(cents: cents, stepCents: 1200.0 / 72.0)
        case .wholeTone:
            return Self.snapEqual(cents: cents, stepCents: 200.0)
        case .justIntonation:
            return Self.snapTable(cents: cents, table: Self.justCents, periodCents: 1200.0)
        case .pythagorean:
            return Self.snapTable(cents: cents, table: Self.pythagCents, periodCents: 1200.0)
        case .harrisonFreeJI:
            return Self.snapTable(cents: cents, table: Self.harrisonCents, periodCents: 1200.0)
        case .partch43:
            return Self.snapTable(cents: cents, table: Self.partch43Cents, periodCents: 1200.0)
        case .carlosAlpha:
            return Self.snapEqual(cents: cents, stepCents: Self.carlosAlphaStep)
        case .carlosBeta:
            return Self.snapEqual(cents: cents, stepCents: Self.carlosBetaStep)
        case .carlosGamma:
            return Self.snapEqual(cents: cents, stepCents: Self.carlosGammaStep)
        case .phi:
            // 13 equal steps within a φ-octave (≈ 833.09 cents).
            let stepCents = Self.phiOctaveCents / 13.0
            return Self.snapEqual(cents: cents, stepCents: stepCents)
        }
    }

    /// Compute the frequency for a target interval (cents) above a root frequency, snapped.
    func frequency(rootHz: Double, cents: Double) -> Double {
        let snapped = snap(cents: cents)
        return rootHz * pow(2.0, snapped / 1200.0)
    }

    /// True if 12-TET note names (C, D, E ...) carry their usual meaning under this tuning.
    /// For phi-tuning we still use the 12 note names as labels for "step 0..11" but pitches
    /// won't correspond to standard western intonation — we surface that in the UI.
    var supportsStandardNoteNames: Bool {
        switch self {
        case .equal12, .equal24, .equal72, .wholeTone, .justIntonation, .pythagorean, .harrisonFreeJI:
            return true
        case .partch43, .carlosAlpha, .carlosBeta, .carlosGamma, .phi:
            // Microtonal / non-octave systems don't map cleanly to C/D/E etc.
            return false
        }
    }

    // MARK: - Helpers

    private static func snapEqual(cents: Double, stepCents: Double) -> Double {
        return (cents / stepCents).rounded() * stepCents
    }

    private static func snapTable(cents: Double, table: [Double], periodCents: Double) -> Double {
        // Reduce into [0, period), keep the octave count, then add back.
        let octaves = floor(cents / periodCents)
        let reduced = cents - octaves * periodCents
        var bestStep = table[0]
        var bestDist = abs(reduced - table[0])
        for c in table.dropFirst() {
            let d = abs(reduced - c)
            if d < bestDist {
                bestDist = d
                bestStep = c
            }
        }
        // Also consider the period boundary (e.g., 1200) for the upper-octave snap.
        let distToPeriod = abs(reduced - periodCents)
        if distToPeriod < bestDist {
            bestStep = periodCents
            bestDist = distToPeriod
        }
        return octaves * periodCents + bestStep
    }
}
