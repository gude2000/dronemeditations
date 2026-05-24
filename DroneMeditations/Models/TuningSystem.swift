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
        case .equal12, .equal24, .equal72, .wholeTone, .justIntonation, .pythagorean:
            return true
        case .phi:
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
