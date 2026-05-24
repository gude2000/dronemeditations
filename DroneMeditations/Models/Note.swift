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
}
