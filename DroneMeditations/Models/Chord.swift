import Foundation

/// A 4-voice chord type defined by intervals (cents from root).
/// Cent values are 12-TET-aligned by default but get snapped to the active tuning system.
struct ChordType: Identifiable, Hashable, Codable {
    var id: String { name }
    let name: String
    let category: Category
    /// Four interval offsets from the root, in cents. Must be exactly 4 entries.
    let intervalsCents: [Double]

    enum Category: String, CaseIterable, Codable {
        case triadic = "Triads & 7ths"
        case extended = "Extensions"
        case modal = "Modal"
        case symmetric = "Symmetric"
        case quartal = "Quartal & Open"
        case microtonal = "Microtonal"
    }

    init(_ name: String, _ category: Category, _ intervalsCents: [Double]) {
        precondition(intervalsCents.count == 4, "ChordType requires exactly 4 voices")
        self.name = name
        self.category = category
        self.intervalsCents = intervalsCents
    }
}

extension ChordType {
    // 12-TET semitone helpers.
    private static func semis(_ s: Double) -> Double { s * 100.0 }

    /// Phi step in cents (one step of φ-divided-by-13 tuning).
    private static let phiStep: Double = log2((1.0 + sqrt(5.0)) / 2.0) * 1200.0 / 13.0

    static let all: [ChordType] = [
        // MARK: Triads + sevenths (root + chord + octave / 4 voices total)
        ChordType("Major",          .triadic, [semis(0), semis(4),  semis(7),  semis(12)]),
        ChordType("Minor",          .triadic, [semis(0), semis(3),  semis(7),  semis(12)]),
        ChordType("Diminished",     .triadic, [semis(0), semis(3),  semis(6),  semis(12)]),
        ChordType("Augmented",      .triadic, [semis(0), semis(4),  semis(8),  semis(12)]),
        ChordType("Sus2",           .triadic, [semis(0), semis(2),  semis(7),  semis(12)]),
        ChordType("Sus4",           .triadic, [semis(0), semis(5),  semis(7),  semis(12)]),
        ChordType("Major 7",        .triadic, [semis(0), semis(4),  semis(7),  semis(11)]),
        ChordType("Minor 7",        .triadic, [semis(0), semis(3),  semis(7),  semis(10)]),
        ChordType("Dominant 7",     .triadic, [semis(0), semis(4),  semis(7),  semis(10)]),
        ChordType("Diminished 7",   .triadic, [semis(0), semis(3),  semis(6),  semis(9)]),
        ChordType("Half-Dim (m7♭5)",.triadic, [semis(0), semis(3),  semis(6),  semis(10)]),
        ChordType("Minor-Maj 7",    .triadic, [semis(0), semis(3),  semis(7),  semis(11)]),
        ChordType("Augmented 7",    .triadic, [semis(0), semis(4),  semis(8),  semis(10)]),

        // MARK: Extensions
        ChordType("Add 9",          .extended, [semis(0), semis(4),  semis(7),  semis(14)]),
        ChordType("Minor Add 9",    .extended, [semis(0), semis(3),  semis(7),  semis(14)]),
        ChordType("6 chord",        .extended, [semis(0), semis(4),  semis(7),  semis(9)]),
        ChordType("Minor 6",        .extended, [semis(0), semis(3),  semis(7),  semis(9)]),
        ChordType("Major 9 (no 5)", .extended, [semis(0), semis(4),  semis(11), semis(14)]),
        ChordType("7 sus4",         .extended, [semis(0), semis(5),  semis(7),  semis(10)]),

        // MARK: Modal — characteristic 4-note slices of each diatonic /
        // harmonic / melodic mode. Picking one of these does two
        // things at once: (1) it sets the four voice pitches to the
        // mode's most identifying degrees, and (2) when Quantize-to-scale
        // is on, the quantize cache fills with these same notes so
        // pitch-LFO modulation arpeggiates *inside the mode* instead of
        // wandering chromatically. Ionian shows up as "Major (mode)"
        // since the maj7 chord already covers the same notes.
        ChordType("Ionian",         .modal, [semis(0),  semis(4),  semis(7),  semis(11)]), // 1 3 5 7
        ChordType("Dorian",         .modal, [semis(0),  semis(3),  semis(9),  semis(10)]), // 1 ♭3 6 ♭7
        ChordType("Phrygian",       .modal, [semis(0),  semis(1),  semis(3),  semis(10)]), // 1 ♭2 ♭3 ♭7
        ChordType("Lydian",         .modal, [semis(0),  semis(4),  semis(6),  semis(11)]), // 1 3 ♯4 7
        ChordType("Mixolydian",     .modal, [semis(0),  semis(4),  semis(7),  semis(10)]), // 1 3 5 ♭7
        ChordType("Aeolian",        .modal, [semis(0),  semis(3),  semis(8),  semis(10)]), // 1 ♭3 ♭6 ♭7
        ChordType("Locrian",        .modal, [semis(0),  semis(1),  semis(6),  semis(10)]), // 1 ♭2 ♭5 ♭7
        ChordType("Harmonic Minor", .modal, [semis(0),  semis(3),  semis(8),  semis(11)]), // 1 ♭3 ♭6 7
        ChordType("Melodic Minor",  .modal, [semis(0),  semis(3),  semis(9),  semis(11)]), // 1 ♭3 6 7

        // MARK: Symmetric (each step is the same interval — drone-friendly)
        ChordType("Whole-Tone",     .symmetric, [semis(0), semis(2),  semis(4),  semis(6)]),
        ChordType("Tritone Stack",  .symmetric, [semis(0), semis(6),  semis(12), semis(18)]),
        ChordType("Minor 3rd Stack",.symmetric, [semis(0), semis(3),  semis(6),  semis(9)]),
        ChordType("Major 3rd Stack",.symmetric, [semis(0), semis(4),  semis(8),  semis(12)]),
        ChordType("Chromatic Cluster",.symmetric,[semis(0), semis(1), semis(2),  semis(3)]),

        // MARK: Quartal / open / drone-style
        ChordType("Quartal",        .quartal, [semis(0), semis(5),  semis(10), semis(15)]),
        ChordType("Quintal",        .quartal, [semis(0), semis(7),  semis(14), semis(21)]),
        ChordType("Open Fifth",     .quartal, [semis(0), semis(7),  semis(12), semis(19)]),
        ChordType("Octaves",        .quartal, [semis(0), semis(12), semis(24), semis(36)]),
        ChordType("Power Drone",    .quartal, [semis(0), semis(7),  semis(12), semis(7)]),

        // MARK: Microtonal — defined directly in cents
        ChordType("Phi Steps",          .microtonal, [0,          phiStep,      phiStep * 2,  phiStep * 3]),
        ChordType("Phi Open",           .microtonal, [0,          phiStep * 2,  phiStep * 4,  phiStep * 6]),
        ChordType("Phi Ratio Stack",    .microtonal, [0,          833.09,       1666.18,      2499.27]),
        ChordType("72-TET Neutral",     .microtonal, [0,          350.0,        700.0,        1050.0]),
        ChordType("Quartertone Cluster",.microtonal, [0,          50.0,         100.0,        150.0]),
        ChordType("Bohlen-Pierce Triad",.microtonal, [0,          854.0,        1466.0,       1902.0]),
        ChordType("7-Limit Harmonic",   .microtonal, [0,          386.31,       701.96,       968.83])
    ]

    static let byCategory: [Category: [ChordType]] = {
        var dict: [Category: [ChordType]] = [:]
        for ct in all {
            dict[ct.category, default: []].append(ct)
        }
        return dict
    }()

    /// Resolve this chord at a given root frequency under the given tuning system.
    /// Returns exactly 4 frequencies in voice order.
    func frequencies(rootHz: Double, tuning: TuningSystem) -> [Double] {
        return intervalsCents.map { tuning.frequency(rootHz: rootHz, cents: $0) }
    }
}
