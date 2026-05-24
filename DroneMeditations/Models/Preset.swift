import Foundation

/// A preset that fully populates all 4 oscillators (frequency + pan).
/// Binaural presets use opposite-ear panning to create a difference-frequency beat.
struct Preset: Identifiable, Hashable {
    var id: String { name }
    let name: String
    let category: Category
    let subtitle: String?
    /// (frequency Hz, pan -1..1) for each of 4 voices.
    let voices: [Voice]

    struct Voice: Hashable {
        let hz: Double
        let pan: Double  // -1..+1
    }

    enum Category: String, CaseIterable {
        case binaural2 = "Binaural — 2 tone"
        case binaural3 = "Binaural — 3 tone"
        case binaural4 = "Binaural — 4 tone"
        case naturalResonance = "Natural Resonance"
        case solfeggio = "Solfeggio"
        case mysticComposers = "Mystic & Composers"
    }

    init(_ name: String, _ category: Category, subtitle: String? = nil, _ voices: [Voice]) {
        precondition(voices.count == 4, "Preset requires exactly 4 voices (pad with silent voices if needed)")
        self.name = name
        self.category = category
        self.subtitle = subtitle
        self.voices = voices
    }
}

extension Preset {
    // Convenience helpers
    private static func L(_ hz: Double) -> Voice { Voice(hz: hz, pan: -1.0) }
    private static func R(_ hz: Double) -> Voice { Voice(hz: hz, pan: +1.0) }
    private static func C(_ hz: Double) -> Voice { Voice(hz: hz, pan: 0.0) }
    /// A silent voice used to pad 2/3-tone presets to 4 voices.
    private static let silent: Voice = Voice(hz: 110.0, pan: 0.0)  // engine will mute this slot

    /// Schumann resonance: 7.83 Hz. Implemented as binaural carrier delta.
    static let all: [Preset] = [
        // MARK: 2-tone binaural
        Preset("Delta 4 Hz (Deep Sleep)",      .binaural2, subtitle: "200 L / 204 R", [L(200), R(204), silent, silent]),
        Preset("Theta 6 Hz (Meditation)",      .binaural2, subtitle: "200 L / 206 R", [L(200), R(206), silent, silent]),
        Preset("Schumann 7.83 Hz",             .binaural2, subtitle: "100 L / 107.83 R", [L(100), R(107.83), silent, silent]),
        Preset("Alpha 10 Hz (Relaxed Focus)",  .binaural2, subtitle: "210 L / 220 R", [L(210), R(220), silent, silent]),
        Preset("Beta 18 Hz (Alert)",           .binaural2, subtitle: "210 L / 228 R", [L(210), R(228), silent, silent]),
        Preset("Gamma 40 Hz (Insight)",        .binaural2, subtitle: "200 L / 240 R", [L(200), R(240), silent, silent]),

        // MARK: 3-tone binaural (carrier + difference + harmonic anchor)
        Preset("Theta Triad",                  .binaural3, subtitle: "Schumann + theta",
               [L(100), R(107.83), C(50), silent]),
        Preset("Alpha + 5th",                  .binaural3, subtitle: "10 Hz beat + perfect 5th drone",
               [L(220), R(230), C(330), silent]),
        Preset("Gamma Layered",                .binaural3, subtitle: "40 Hz with octave bedding",
               [L(200), R(240), C(100), silent]),

        // MARK: 4-tone binaural — two stereo pairs producing two simultaneous beats
        Preset("Dual Theta",                   .binaural4, subtitle: "6 Hz + 4 Hz cross-beat",
               [L(200), R(206), L(330), R(334)]),
        Preset("Alpha + Gamma",                .binaural4, subtitle: "10 Hz and 40 Hz coexisting",
               [L(220), R(230), L(300), R(340)]),
        Preset("Phi-Tuned Field",              .binaural4, subtitle: "Golden-ratio carriers, theta beat",
               [L(132), R(138), L(213.5), R(219.5)]),
        Preset("Complex Schumann",             .binaural4, subtitle: "7.83 + 14.3 + 20.8 layers",
               [L(100), R(107.83), L(200), R(214.3)]),

        // MARK: Natural resonance
        Preset("Earth (Schumann fundamental)", .naturalResonance, subtitle: "7.83 Hz",
               [L(100), R(107.83), C(50), silent]),
        Preset("C-φ (Jose/Alex)",              .naturalResonance, subtitle: "266.67 Hz — the icon-generator frequency",
               [L(133.33), C(266.67), C(266.67), R(533.33)]),
        Preset("Jose & Alex Phi Augmented Chord", .naturalResonance, subtitle: "C–E–G♯ tuned to 1 : √φ : φ — the Webb triangle",
               [L(164.81), C(266.67), R(209.64), silent]),
        Preset("Sable's Chord",                .naturalResonance, subtitle: "φ-tuned C-E-G♯ on the φ-tuned C — 1 : √φ : φ",
               [L(266.67), C(339.20), R(431.36), silent]),
        Preset("OM 136.1 Hz",                  .naturalResonance, subtitle: "Tuned to Earth's year",
               [C(136.1), C(272.2), L(204.15), R(204.15)]),
        Preset("Moon 210.42 Hz",               .naturalResonance, subtitle: "Cosmic-octave moon orbit",
               [C(210.42), L(105.21), R(315.63), C(420.84)]),
        Preset("Sun 126.22 Hz",                .naturalResonance, subtitle: "Cosmic-octave solar",
               [C(126.22), L(63.11), R(189.33), C(252.44)]),

        // MARK: Mystic & Composers — Scriabin's Mystic Chord (Prometheus): C-F♯-B♭-E-A-D
        Preset("Scriabin 1 — Mystic Core",  .mysticComposers, subtitle: "C–F♯–B♭–E (lower 4 of the mystic chord)",
               [L(130.81), C(185.00), C(233.08), R(329.63)]),
        Preset("Scriabin 2 — Mystic Upper", .mysticComposers, subtitle: "F♯–B♭–E–A (upper 4 of the mystic chord)",
               [L(185.00), C(233.08), C(329.63), R(440.00)]),
        Preset("Scriabin 3 — Wide Mystic",  .mysticComposers, subtitle: "C–B♭–A–D (spread voicing, dropped F♯/E)",
               [L(130.81), C(233.08), C(440.00), R(587.33)]),

        // MARK: Solfeggio
        Preset("Solfeggio 396 Hz", .solfeggio, subtitle: "Liberating guilt",        [C(396), L(198), R(594), silent]),
        Preset("Solfeggio 417 Hz", .solfeggio, subtitle: "Facilitating change",     [C(417), L(208.5), R(625.5), silent]),
        Preset("Solfeggio 528 Hz", .solfeggio, subtitle: "Repair / DNA",            [C(528), L(264), R(792), silent]),
        Preset("Solfeggio 639 Hz", .solfeggio, subtitle: "Connection",              [C(639), L(319.5), R(958.5), silent]),
        Preset("Solfeggio 741 Hz", .solfeggio, subtitle: "Awakening intuition",     [C(741), L(370.5), R(1111.5), silent]),
        Preset("Solfeggio 852 Hz", .solfeggio, subtitle: "Returning to order",      [C(852), L(426), R(1278), silent]),
    ]

    static let byCategory: [Category: [Preset]] = {
        var dict: [Category: [Preset]] = [:]
        for p in all {
            dict[p.category, default: []].append(p)
        }
        return dict
    }()
}
