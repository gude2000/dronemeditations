import Foundation

/// A pitch class (C, C#, D, ..., B) — 12 chromatic names.
enum PitchClass: Int, CaseIterable, Identifiable, Codable {
    case c = 0, cSharp, d, dSharp, e, f, fSharp, g, gSharp, a, aSharp, b

    var id: Int { rawValue }

    var displayName: String {
        switch self {
        case .c: return "C"
        case .cSharp: return "C♯"
        case .d: return "D"
        case .dSharp: return "D♯"
        case .e: return "E"
        case .f: return "F"
        case .fSharp: return "F♯"
        case .g: return "G"
        case .gSharp: return "G♯"
        case .a: return "A"
        case .aSharp: return "A♯"
        case .b: return "B"
        }
    }

    /// Semitones from A within an octave.
    /// A=0, A♯=1, B=2, C=3, ... ; useful for deriving frequency from A=440.
    var semitonesFromA: Int {
        // PitchClass uses C=0 .. B=11. A is rawValue 9.
        // Offset so A=0, A♯=1, B=2, C=3, ...
        return (rawValue - 9 + 12) % 12
    }

    /// Nearest 12-TET pitch class for a given frequency. Used to derive the
    /// chord-pill key from a bundled preset's per-voice Hz at load time —
    /// older bundled presets define voices as raw frequencies without an
    /// explicit key field, so the chord pill would otherwise keep showing
    /// whatever the user last picked. Octave-agnostic (e.g. 110 Hz,
    /// 220 Hz, 440 Hz all → A).
    static func nearestPitchClass(forHz hz: Double) -> PitchClass {
        guard hz > 0 else { return .a }
        // Semitones above A4 (440 Hz), positive or negative, rounded
        let semisFromA4 = (12.0 * log2(hz / 440.0)).rounded()
        // Reduce to 0..11 representing semitones-from-A within an octave
        let semisFromA = ((Int(semisFromA4) % 12) + 12) % 12
        return PitchClass.allCases.first { $0.semitonesFromA == semisFromA } ?? .a
    }
}

/// A pitch = (pitch class, octave). Octave uses scientific pitch notation, C4 = middle C.
struct Pitch: Hashable, Codable {
    var pitchClass: PitchClass
    var octave: Int  // C4 = 4

    /// MIDI note number. C4 = 60, A4 = 69.
    var midi: Int {
        // MIDI: C(-1) = 0. So MIDI for pitchClass p in octave o is (o + 1) * 12 + p.rawValue
        return (octave + 1) * 12 + pitchClass.rawValue
    }

    init(_ pitchClass: PitchClass, octave: Int) {
        self.pitchClass = pitchClass
        self.octave = octave
    }

    /// Semitones above A4 (MIDI 69).
    var semitonesAboveA4: Int { midi - 69 }

    /// Frequency in 12-TET with A4 = 440.
    func frequencyEqual12(referenceA4: Double = 440.0) -> Double {
        return referenceA4 * pow(2.0, Double(semitonesAboveA4) / 12.0)
    }

    /// All 12 keys at a chosen octave (used by the key picker).
    static func allKeys(at octave: Int) -> [Pitch] {
        return PitchClass.allCases.map { Pitch($0, octave: octave) }
    }

    /// Nearest 12-TET pitch (class + octave) for a given frequency. Used
    /// by bundled-preset load so the chord-pill key AND octave both match
    /// the preset's actual voice frequencies. Without both, a chord change
    /// later in playback derives the new root in the wrong octave (e.g.
    /// preset was E2 ≈ 82 Hz, chord change to D in stale octave 3 jumps
    /// voices to D3 ≈ 147 Hz — nearly an octave up).
    static func nearestPitch(forHz hz: Double, referenceA4: Double = 440.0) -> Pitch {
        guard hz > 0 else { return Pitch(.a, octave: 4) }
        // MIDI 69 == A4. semitones-from-A4 can be negative (below A4).
        let semisFromA4 = Int((12.0 * log2(hz / referenceA4)).rounded())
        let midi = 69 + semisFromA4
        // Scientific pitch: MIDI 60 = C4 → octave = midi/12 - 1.
        // Use floor-div to handle negative MIDI cleanly (e.g. very low Hz).
        let octave = Int((Double(midi) / 12.0).rounded(.down)) - 1
        // Pitch class within the chromatic ring: MIDI mod 12 maps to
        // C..B (0..11) — same as PitchClass.rawValue.
        let pcRaw = ((midi % 12) + 12) % 12
        let pc = PitchClass(rawValue: pcRaw) ?? .a
        return Pitch(pc, octave: octave)
    }
}
