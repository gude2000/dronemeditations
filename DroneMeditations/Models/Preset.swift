import Foundation

/// A preset that fully populates all 4 oscillators (frequency + pan).
/// Binaural presets use opposite-ear panning to create a difference-frequency beat.
///
/// Hashable conformance is manual (by name) because `Voice` carries optional
/// nested structs (FilterState, DelayState, etc.) — composing Hashable across
/// all of them adds noise and requires every nested type to opt in.
struct Preset: Identifiable, Hashable {
    var id: String { name }
    let name: String
    let category: Category
    let subtitle: String?
    /// (frequency Hz, pan -1..1) for each of 4 voices.
    let voices: [Voice]

    static func == (lhs: Preset, rhs: Preset) -> Bool { lhs.name == rhs.name }
    func hash(into hasher: inout Hasher) { hasher.combine(name) }

    struct Voice {
        let hz: Double
        let pan: Double  // -1..+1
        // All fields below are optional. applyPreset only pushes the ones that
        // are non-nil so simple presets (just hz + pan) keep their existing
        // behavior of leaving the user's per-voice tone untouched. These
        // optional fields are how the Drone Artists category captures full
        // sound character — waveform, FX, LFOs, drift — not just pitches.
        let wave: Waveform?
        let amp: Double?
        let drive: Double?
        let startDelaySec: Double?
        let playDurationSec: Double?
        /// Replay cycles for the timing envelope. nil = play once (v1.0
        /// behavior, the implicit default for every preset shipped before
        /// this field existed). 2/3/5 = repeat N times. 0 = ∞.
        let replayCount: Int?
        let filter: FilterState?
        let reverb: ReverbState?
        let delay: DelayState?
        let chorus: ChorusState?
        let fm: FMState?
        /// Granular synth settings — only consumed when wave == .granular.
        let grain: GrainState?
        /// Per-LFO overrides. nil entries (or fewer than 4) leave the
        /// corresponding LFO alone; non-nil entries replace it.
        let lfos: [LfoState?]?
        let drift: DriftVoiceConfig?

        init(hz: Double, pan: Double = 0,
             wave: Waveform? = nil, amp: Double? = nil,
             drive: Double? = nil,
             startDelaySec: Double? = nil,
             playDurationSec: Double? = nil,
             replayCount: Int? = nil,
             filter: FilterState? = nil,
             reverb: ReverbState? = nil,
             delay: DelayState? = nil,
             chorus: ChorusState? = nil,
             fm: FMState? = nil,
             grain: GrainState? = nil,
             lfos: [LfoState?]? = nil,
             drift: DriftVoiceConfig? = nil) {
            self.hz = hz; self.pan = pan
            self.wave = wave; self.amp = amp
            self.drive = drive
            self.startDelaySec = startDelaySec
            self.playDurationSec = playDurationSec
            self.replayCount = replayCount
            self.filter = filter; self.reverb = reverb
            self.delay = delay; self.chorus = chorus
            self.fm = fm; self.grain = grain
            self.lfos = lfos; self.drift = drift
        }
    }

    enum Category: String, CaseIterable {
        case droneArtists = "Drone Artists"
        case binaural2 = "Binaural — 2 tone"
        case binaural3 = "Binaural — 3 tone"
        case binaural4 = "Binaural — 4 tone"
        case naturalResonance = "Natural Resonance"
        case cymatics = "Cymatics"
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

        // MARK: Cymatics — patterns chosen for striking symmetric nodal geometries.
        Preset("Hypogeum 111 Hz",          .cymatics, subtitle: "Maltese megalithic chamber — single-tone radial symmetry",
               [L(55.5), C(111), R(222), silent]),
        Preset("Harmonic Series 1:2:3:4",  .cymatics, subtitle: "100·200·300·400 Hz — clean orthogonal grid",
               [L(100), C(200), C(300), R(400)]),
        Preset("Just Major Triad 4:5:6",   .cymatics, subtitle: "C-E-G+C in pure intonation — 5-fold floral pattern",
               [L(264), C(330), C(396), R(528)]),
        Preset("Octave Stack 1:2:4:8",     .cymatics, subtitle: "75·150·300·600 Hz — pure-doubling lattice",
               [L(75), C(150), C(300), R(600)]),
        Preset("Perfect Fifths 2:3:9/2:27/4", .cymatics, subtitle: "100·150·225·337.5 Hz — recursive triangular symmetries",
               [L(100), C(150), C(225), R(337.5)]),
        Preset("Fibonacci Quartet",        .cymatics, subtitle: "100·162·262·424 Hz — φ-progression spiral patterns",
               [L(100), C(162), C(262), R(424)]),

        // MARK: Mystic & Composers — Scriabin's Mystic Chord (Prometheus): C-F♯-B♭-E-A-D
        Preset("Scriabin 1 — Mystic Core",  .mysticComposers, subtitle: "C–F♯–B♭–E (lower 4 of the mystic chord)",
               [L(130.81), C(185.00), C(233.08), R(329.63)]),
        Preset("Scriabin 2 — Mystic Upper", .mysticComposers, subtitle: "F♯–B♭–E–A (upper 4 of the mystic chord)",
               [L(185.00), C(233.08), C(329.63), R(440.00)]),
        Preset("Scriabin 3 — Wide Mystic",  .mysticComposers, subtitle: "C–B♭–A–D (spread voicing, dropped F♯/E)",
               [L(130.81), C(233.08), C(440.00), R(587.33)]),

        // Ligeti — Atmosphères-style chromatic micropolyphony clusters
        Preset("Ligeti 1 — Chromatic Cluster", .mysticComposers, subtitle: "C-C♯-D-D♯ tight semitone wash (Atmosphères opening)",
               [L(130.81), C(138.59), C(146.83), R(155.56)]),
        Preset("Ligeti 2 — Whole-Tone Cluster", .mysticComposers, subtitle: "C-D-E-F♯ whole-tone fragment, shimmering",
               [L(130.81), C(146.83), C(164.81), R(185.00)]),
        Preset("Ligeti 3 — Microtone Cluster", .mysticComposers, subtitle: "Quartertone cluster around A3 — 215·220·225·230 Hz",
               [L(215), C(220), C(225), R(230)]),

        // MARK: Solfeggio
        //
        // The Solfeggio frequencies are a modern (1970s, Puleo) numerological
        // set popularly attributed with specific therapeutic effects. Those
        // effects (DNA repair, detox, chakra activation, etc.) aren't
        // clinically validated — the subtitles below reflect the *traditional
        // associations*, not endorsed mechanisms. Meditative benefit comes
        // from sustained drone-tone listening, not the integer Hz value.
        Preset("Solfeggio 396 Hz", .solfeggio, subtitle: "Traditionally associated with releasing fear & guilt", [C(396), L(198),   R(594),    silent]),
        Preset("Solfeggio 417 Hz", .solfeggio, subtitle: "Traditionally associated with breaking patterns",      [C(417), L(208.5), R(625.5),  silent]),
        Preset("Solfeggio 528 Hz", .solfeggio, subtitle: "Traditionally called the \"miracle\" tone",             [C(528), L(264),   R(792),    silent]),
        Preset("Solfeggio 639 Hz", .solfeggio, subtitle: "Traditionally associated with relational harmony",     [C(639), L(319.5), R(958.5),  silent]),
        Preset("Solfeggio 741 Hz", .solfeggio, subtitle: "Traditionally associated with insight",                [C(741), L(370.5), R(1111.5), silent]),
        Preset("Solfeggio 852 Hz", .solfeggio, subtitle: "Traditionally associated with restoring balance",      [C(852), L(426),   R(1278),   silent]),

        // Extended Solfeggio set + Verdi 432
        Preset("Solfeggio 96 Hz",          .solfeggio, subtitle: "Sub-bass grounding tone",                       [C(96),  L(48),    R(192),  silent]),
        Preset("Solfeggio 174 Hz",         .solfeggio, subtitle: "Traditionally associated with grounding",       [C(174), L(87),    R(348),  silent]),
        Preset("Solfeggio 285 Hz",         .solfeggio, subtitle: "Traditionally associated with body restoration",[C(285), L(142.5), R(570),  silent]),
        Preset("Solfeggio 432 Hz (Verdi)", .solfeggio, subtitle: "Alternative natural-tuning A",                  [C(432), L(216),   R(864),  silent]),
        Preset("Solfeggio 963 Hz",         .solfeggio, subtitle: "Traditionally associated with the crown chakra",[C(963), L(481.5), R(1926), silent]),

        // ─────────────────────────────────────────────────────────────
        // MARK: Drone Artists — tributes to long-form drone pioneers
        //
        // These presets carry full voice character (waveform, filter, FX,
        // sometimes LFOs + drift) so loading captures the *sound* of the
        // artist's signature, not just their pitches. Tributes, not
        // transcriptions — starting points for exploring each sound world.
        // ─────────────────────────────────────────────────────────────

        // Pauline Oliveros — Deep A Resonance (staggered entries at 0/1/2/4 min)
        Preset("Oliveros — Deep A Resonance", .droneArtists,
               subtitle: "Pauline Oliveros · slow A drone · voices enter at 0 / 1 / 2 / 4 min",
               [
                Voice(hz: 110.00,  pan: -0.4, wave: .sine, amp: 0.55,
                      reverb: ReverbState(decaySec: 8.0, mix: 0.40),
                      lfos: [LfoState(shape: .sine, targets: [.amplitude], rateHz: 0.07, depth: 0.30), nil, nil, nil]),
                Voice(hz: 220.12,  pan:  0.4, wave: .sine, amp: 0.50,
                      startDelaySec: 60,
                      reverb: ReverbState(decaySec: 8.0, mix: 0.40),
                      lfos: [LfoState(shape: .sine, targets: [.amplitude], rateHz: 0.09, depth: 0.35), nil, nil, nil]),
                Voice(hz: 329.85,  pan: -0.2, wave: .sine, amp: 0.42,
                      startDelaySec: 120,
                      reverb: ReverbState(decaySec: 8.0, mix: 0.40),
                      lfos: [LfoState(shape: .sine, targets: [.amplitude], rateHz: 0.06, depth: 0.40), nil, nil, nil]),
                Voice(hz: 440.00,  pan:  0.2, wave: .sine, amp: 0.38,
                      startDelaySec: 240,
                      reverb: ReverbState(decaySec: 8.0, mix: 0.40),
                      lfos: [LfoState(shape: .sine, targets: [.amplitude], rateHz: 0.08, depth: 0.35), nil, nil, nil])
               ]),

        // Terry Riley — Rainbow Repetition (cascade staggered at 0/15/45/90 s)
        Preset("Riley — Rainbow Repetition", .droneArtists,
               subtitle: "Terry Riley · just C major cascade · voices enter at 0 / 15 / 45 / 90 s",
               {
                   let dly = DelayState(timeSec: 0.30, feedback: 0.65, mix: 0.40, mode: .pingPong, timing: .eighth)
                   let cho = ChorusState(rateHz: 0.6, depth: 0.5, width: 0.8, mix: 0.25)
                   return [
                    Voice(hz: 130.81, pan:  0.0,  wave: .triangle, amp: 0.50, delay: dly, chorus: cho),
                    Voice(hz: 196.22, pan: -0.4,  wave: .triangle, amp: 0.45,
                          startDelaySec: 15, delay: dly, chorus: cho),
                    Voice(hz: 261.63, pan:  0.4,  wave: .triangle, amp: 0.45,
                          startDelaySec: 45, delay: dly, chorus: cho),
                    Voice(hz: 327.04, pan: -0.1,  wave: .triangle, amp: 0.42,
                          startDelaySec: 90, delay: dly, chorus: cho)
                   ]
               }()),

        // Éliane Radigue — Île Re-Sonante
        Preset("Radigue — Île Re-Sonante", .droneArtists,
               subtitle: "Éliane Radigue · 4¢ + 0.3 Hz beating · static-seeming, ever-shifting",
               {
                   let rev = ReverbState(decaySec: 7.0, mix: 0.30)
                   return [
                    Voice(hz:  73.42, pan: -0.5, wave: .sine, amp: 0.62, reverb: rev),
                    Voice(hz:  73.59, pan:  0.5, wave: .sine, amp: 0.62, reverb: rev),
                    Voice(hz: 220.00, pan: -0.2, wave: .sine, amp: 0.38, reverb: rev),
                    Voice(hz: 220.30, pan:  0.2, wave: .sine, amp: 0.38, reverb: rev)
                   ]
               }()),

        // Stars of the Lid — Orchestral Halo (chord blooms at 0/30/90/180 s)
        Preset("Stars of the Lid — Orchestral Halo", .droneArtists,
               subtitle: "Stars of the Lid · A major halo · chord blooms 0 / 30 / 90 / 180 s",
               {
                   let rev = ReverbState(decaySec: 10.0, mix: 0.45)
                   let cho = ChorusState(rateHz: 0.4, depth: 0.5, width: 1.0, mix: 0.30)
                   func mkLFO(_ rate: Double) -> [LfoState?] {
                       [nil, LfoState(shape: .sine, targets: [.cutoff], rateHz: rate, depth: 0.35), nil, nil]
                   }
                   return [
                    Voice(hz: 110.00, pan: -0.4, wave: .sawtooth, amp: 0.50,
                          filter: FilterState(type: .lowpass, cutoffHz: 800,  q: 1.5),
                          reverb: rev, chorus: cho, lfos: mkLFO(0.05)),
                    Voice(hz: 164.81, pan:  0.4, wave: .sawtooth, amp: 0.45,
                          startDelaySec: 30,
                          filter: FilterState(type: .lowpass, cutoffHz: 900,  q: 1.5),
                          reverb: rev, chorus: cho, lfos: mkLFO(0.04)),
                    Voice(hz: 220.00, pan: -0.2, wave: .sawtooth, amp: 0.40,
                          startDelaySec: 90,
                          filter: FilterState(type: .lowpass, cutoffHz: 1100, q: 1.5),
                          reverb: rev, chorus: cho, lfos: mkLFO(0.06)),
                    Voice(hz: 277.18, pan:  0.2, wave: .sawtooth, amp: 0.35,
                          startDelaySec: 180,
                          filter: FilterState(type: .lowpass, cutoffHz: 1300, q: 1.5),
                          reverb: rev, chorus: cho, lfos: mkLFO(0.05))
                   ]
               }()),

        // Sunn O))) — Onyx Tar  (drop master volume — heavy stack)
        Preset("Sunn O))) — Onyx Tar", .droneArtists,
               subtitle: "Sunn O))) · sub-bass E + amp drive · square tremolo · drop master volume",
               {
                   let rev = ReverbState(decaySec: 9.0, mix: 0.45)
                   let trem: [LfoState?] = [LfoState(shape: .square, targets: [.amplitude], rateHz: 0.7, depth: 0.30), nil, nil, nil]
                   return [
                    Voice(hz:  41.20, pan: -0.5, wave: .sawtooth, amp: 0.75, drive: 6.5,
                          filter: FilterState(type: .lowpass, cutoffHz: 350, q: 2.0),
                          reverb: rev, lfos: trem),
                    Voice(hz:  41.55, pan:  0.5, wave: .square,   amp: 0.65, drive: 5.5,
                          filter: FilterState(type: .lowpass, cutoffHz: 400, q: 1.8),
                          reverb: rev, lfos: trem),
                    Voice(hz:  82.40, pan:  0.0, wave: .sawtooth, amp: 0.55, drive: 4.0,
                          filter: FilterState(type: .lowpass, cutoffHz: 500, q: 1.5), reverb: rev),
                    Voice(hz: 123.47, pan:  0.1, wave: .sawtooth, amp: 0.40, drive: 3.0,
                          filter: FilterState(type: .lowpass, cutoffHz: 700, q: 1.5), reverb: rev)
                   ]
               }()),

        // William Basinski — Disintegration
        Preset("Basinski — Disintegration", .droneArtists,
               subtitle: "Basinski · tape-loop voice + pink-noise hiss · C major support",
               {
                   let rev = ReverbState(decaySec: 7.0, mix: 0.40)
                   return [
                    Voice(hz: 261.63, pan: 0.0, wave: .triangle, amp: 0.55, drive: 1.8,
                          filter: FilterState(type: .lowpass, cutoffHz: 1500, q: 1.0),
                          reverb: rev,
                          delay: DelayState(timeSec: 0.50, feedback: 0.65, mix: 0.40, mode: .stereo, timing: .quarter),
                          chorus: nil, fm: nil,
                          lfos: [
                            LfoState(shape: .sine, targets: [.amplitude], rateHz: 0.08, depth: 0.45),
                            LfoState(shape: .sine, targets: [.cutoff],    rateHz: 0.03, depth: 0.55),
                            nil, nil
                          ]),
                    Voice(hz: 130.81, pan:  0.0, wave: .sine, amp: 0.45, reverb: rev),
                    Voice(hz: 392.00, pan: -0.3, wave: .sine, amp: 0.35, reverb: rev),
                    // Pink-noise tape-hiss layer — joins at 90 s, then takes
                    // over as the melodic voice fades. HP keeps it airy. The
                    // late entry sells the disintegration narrative — the loop
                    // wears out and the noise floor takes its place.
                    Voice(hz: 220.00, pan: 0.0, wave: .pinkNoise, amp: 0.22,
                          startDelaySec: 90,
                          filter: FilterState(type: .highpass, cutoffHz: 600, q: 0.7),
                          reverb: rev,
                          lfos: [LfoState(shape: .sine, targets: [.amplitude], rateHz: 0.08, depth: 0.55), nil, nil, nil])
                   ]
               }()),

        // Phill Niblock — Tight Cluster
        Preset("Niblock — Tight Cluster", .droneArtists,
               subtitle: "Phill Niblock · 4-voice microtonal cluster · beating as harmony",
               {
                   let f = FilterState(type: .lowpass, cutoffHz: 2000, q: 0.7)
                   let r = ReverbState(decaySec: 3.0, mix: 0.20)
                   return [
                    Voice(hz: 220.00, pan: -0.8, wave: .sawtooth, amp: 0.45, filter: f, reverb: r),
                    Voice(hz: 222.55, pan: -0.3, wave: .sawtooth, amp: 0.45, filter: f, reverb: r),
                    Voice(hz: 218.45, pan:  0.3, wave: .sawtooth, amp: 0.45, filter: f, reverb: r),
                    Voice(hz: 221.25, pan:  0.8, wave: .sawtooth, amp: 0.45, filter: f, reverb: r)
                   ]
               }()),

        // Charlemagne Palestine — Strumming Overtones
        Preset("Palestine — Strumming Overtones", .droneArtists,
               subtitle: "Charlemagne Palestine · just D + 5/4 F# · piano-sustain chorus wash",
               {
                   let cho = ChorusState(rateHz: 0.5, depth: 0.7, width: 1.0, mix: 0.40)
                   let rev = ReverbState(decaySec: 5.0, mix: 0.35)
                   return [
                    Voice(hz:  73.42, pan: -0.2, wave: .triangle, amp: 0.60, reverb: rev, chorus: cho),
                    Voice(hz:  91.78, pan:  0.2, wave: .triangle, amp: 0.50, reverb: rev, chorus: cho),
                    Voice(hz: 220.00, pan: -0.4, wave: .sawtooth, amp: 0.38,
                          filter: FilterState(type: .lowpass, cutoffHz: 2500, q: 0.7),
                          reverb: rev, chorus: cho),
                    Voice(hz: 293.66, pan:  0.4, wave: .sawtooth, amp: 0.38,
                          filter: FilterState(type: .lowpass, cutoffHz: 2800, q: 0.7),
                          reverb: rev, chorus: cho)
                   ]
               }()),

        // Yoshi Wada — Bagpipe Drone
        Preset("Wada — Bagpipe Drone", .droneArtists,
               subtitle: "Yoshi Wada · just A + 3/2 + 9/8 · reed wobble + multi-reed chorus",
               {
                   let cho = ChorusState(rateHz: 0.7, depth: 0.6, width: 0.7, mix: 0.40)
                   let rev = ReverbState(decaySec: 4.0, mix: 0.30)
                   let wobble: [LfoState?] = [nil, nil, nil, LfoState(shape: .sine, targets: [.pitch], rateHz: 5.0, depth: 0.02)]
                   return [
                    Voice(hz: 110.00, pan:  0.0, wave: .sawtooth, amp: 0.65,
                          filter: FilterState(type: .lowpass, cutoffHz: 1800, q: 1.0),
                          reverb: rev, chorus: cho, lfos: wobble),
                    Voice(hz: 220.00, pan: -0.4, wave: .sawtooth, amp: 0.45,
                          filter: FilterState(type: .lowpass, cutoffHz: 2200, q: 1.0),
                          reverb: rev, chorus: cho),
                    Voice(hz: 165.00, pan:  0.4, wave: .sawtooth, amp: 0.42,
                          filter: FilterState(type: .lowpass, cutoffHz: 2000, q: 1.0),
                          reverb: rev, chorus: cho),
                    Voice(hz: 247.50, pan: -0.2, wave: .sawtooth, amp: 0.30,
                          filter: FilterState(type: .lowpass, cutoffHz: 2500, q: 1.0),
                          reverb: rev, chorus: cho)
                   ]
               }()),

        // Harold Budd — Pearl Pad
        Preset("Budd — Pearl Pad", .droneArtists,
               subtitle: "Harold Budd · soft Cmaj7 pad · breathing amp LFO · 9 s reverb halo",
               {
                   let rev = ReverbState(decaySec: 9.0, mix: 0.50)
                   let cho = ChorusState(rateHz: 0.3, depth: 0.4, width: 0.6, mix: 0.25)
                   func br(_ rate: Double) -> [LfoState?] {
                       [LfoState(shape: .sine, targets: [.amplitude], rateHz: rate, depth: 0.40), nil, nil, nil]
                   }
                   return [
                    Voice(hz: 130.81, pan: -0.3, wave: .sine,     amp: 0.50, reverb: rev, chorus: cho, lfos: br(0.04)),
                    Voice(hz: 196.00, pan:  0.3, wave: .sine,     amp: 0.45, reverb: rev, chorus: cho, lfos: br(0.05)),
                    Voice(hz: 261.63, pan: -0.2, wave: .triangle, amp: 0.38, reverb: rev, chorus: cho, lfos: br(0.03)),
                    Voice(hz: 329.63, pan:  0.2, wave: .triangle, amp: 0.35, reverb: rev, chorus: cho, lfos: br(0.045))
                   ]
               }()),

        // Alice Coltrane — Spiritual Organ
        Preset("Coltrane — Spiritual Organ", .droneArtists,
               subtitle: "Alice Coltrane · Bbm7 organ · Leslie pan rotation + tremolo",
               {
                   let rev = ReverbState(decaySec: 4.0, mix: 0.40)
                   let cho = ChorusState(rateHz: 6.0, depth: 0.7, width: 1.0, mix: 0.50)
                   let leslie: [LfoState?] = [nil, nil, LfoState(shape: .sine, targets: [.pan], rateHz: 0.8, depth: 0.40), nil]
                   return [
                    Voice(hz:  58.27, pan:  0.0, wave: .sawtooth, amp: 0.60,
                          filter: FilterState(type: .lowpass, cutoffHz: 1500, q: 1.0),
                          reverb: rev, chorus: cho, lfos: leslie),
                    Voice(hz: 116.54, pan: -0.4, wave: .sawtooth, amp: 0.45,
                          filter: FilterState(type: .lowpass, cutoffHz: 2000, q: 1.0),
                          reverb: rev, chorus: cho, lfos: leslie),
                    Voice(hz: 174.61, pan:  0.4, wave: .sawtooth, amp: 0.40,
                          filter: FilterState(type: .lowpass, cutoffHz: 2200, q: 1.0),
                          reverb: rev, chorus: cho, lfos: leslie),
                    Voice(hz: 207.65, pan:  0.0, wave: .triangle, amp: 0.36, reverb: rev, chorus: cho)
                   ]
               }()),

        // Earth — Tar Pit  (Earth 2 style)
        Preset("Earth — Tar Pit", .droneArtists,
               subtitle: "Earth (Carlson) · Earth-2 doom · driven low B + 4th · 10 s reverb",
               {
                   let rev = ReverbState(decaySec: 10.0, mix: 0.50)
                   func descend(phase: Double) -> DriftVoiceConfig {
                       DriftVoiceConfig(pitchMode: .glacial, pitchAmount: 0.3, pitchPhase: phase,
                                        panMode: .static, panAmount: 0, panPhase: 0)
                   }
                   return [
                    Voice(hz:  30.87, pan: -0.3, wave: .sawtooth, amp: 0.70, drive: 4.5,
                          filter: FilterState(type: .lowpass, cutoffHz: 250, q: 2.0),
                          reverb: rev, drift: descend(phase: 0.0)),
                    Voice(hz:  41.20, pan:  0.3, wave: .sawtooth, amp: 0.65, drive: 4.0,
                          filter: FilterState(type: .lowpass, cutoffHz: 280, q: 1.8),
                          reverb: rev, drift: descend(phase: 0.25)),
                    Voice(hz:  61.74, pan:  0.0, wave: .square,   amp: 0.50, drive: 3.0,
                          filter: FilterState(type: .lowpass, cutoffHz: 400, q: 1.5), reverb: rev),
                    Voice(hz:  92.50, pan:  0.0, wave: .sine,     amp: 0.35, reverb: rev)
                   ]
               }()),

        // Nurse With Wound — Avant Tableau
        Preset("Nurse With Wound — Avant Tableau", .droneArtists,
               subtitle: "NWW · driven saw + S&H square + white-noise bursts + ping-pong 1/4T",
               {
                   let rev = ReverbState(decaySec: 6.0, mix: 0.35)
                   return [
                    Voice(hz:  87.31, pan: -0.8, wave: .sawtooth, amp: 0.50, drive: 3.0,
                          filter: FilterState(type: .lowpass, cutoffHz: 900, q: 1.0),
                          reverb: rev,
                          delay: DelayState(timeSec: 0.40, feedback: 0.55, mix: 0.30, mode: .pingPong, timing: .quarterT),
                          fm: FMState(sourceIndex: 3, index: 60)),
                    Voice(hz: 233.08, pan:  0.8, wave: .square,   amp: 0.35, drive: 2.0,
                          filter: FilterState(type: .highpass, cutoffHz: 400, q: 2.5),
                          reverb: rev,
                          lfos: [nil, LfoState(shape: .sampleAndHold, targets: [.cutoff], rateHz: 0.15, depth: 0.55), nil, nil]),
                    Voice(hz: 311.13, pan: -0.3, wave: .sine,     amp: 0.30, reverb: rev),
                    // White noise w/ S&H amp LFO + wandering BP — intermittent
                    // texture bursts at irregular intervals, very NWW.
                    Voice(hz: 220.00, pan: 0.3, wave: .whiteNoise, amp: 0.30,
                          filter: FilterState(type: .bandpass, cutoffHz: 1200, q: 4.0),
                          reverb: rev,
                          lfos: [
                            LfoState(shape: .sampleAndHold, targets: [.amplitude], rateHz: 0.30, depth: 0.80),
                            LfoState(shape: .sine, targets: [.cutoff], rateHz: 0.10, depth: 0.50),
                            nil, nil
                          ])
                   ]
               }()),

        // Keiji Haino — Spectral Shimmer
        Preset("Haino — Spectral Shimmer", .droneArtists,
               subtitle: "Keiji Haino · D drone + HP shimmer · wobble + chorus halo",
               {
                   let cho = ChorusState(rateHz: 1.5, depth: 0.7, width: 1.0, mix: 0.50)
                   let rev = ReverbState(decaySec: 5.0, mix: 0.40)
                   func wob(_ rate: Double) -> [LfoState?] {
                       [nil, nil, nil, LfoState(shape: .sine, targets: [.pitch], rateHz: rate, depth: 0.05)]
                   }
                   return [
                    Voice(hz:   73.42, pan:  0.0, wave: .sawtooth, amp: 0.55, drive: 3.5,
                          filter: FilterState(type: .lowpass, cutoffHz: 800, q: 2.0),
                          reverb: rev, chorus: cho),
                    Voice(hz:  880.00, pan: -0.6, wave: .sawtooth, amp: 0.22,
                          filter: FilterState(type: .highpass, cutoffHz: 600, q: 3.0),
                          reverb: rev, chorus: cho, lfos: wob(0.8)),
                    Voice(hz: 1108.73, pan:  0.6, wave: .sawtooth, amp: 0.18,
                          filter: FilterState(type: .highpass, cutoffHz: 700, q: 3.0),
                          reverb: rev, chorus: cho, lfos: wob(0.7)),
                    Voice(hz:  220.00, pan:  0.0, wave: .square,   amp: 0.25,
                          filter: FilterState(type: .lowpass, cutoffHz: 1500, q: 1.0),
                          reverb: rev)
                   ]
               }()),

        // ─── Granular presets (T14) ─────────────────────────────────────
        // Four atmospheric pieces showing the range of granular textures —
        // from sparse geiger / rain drops up to dense crackle clouds.

        // Geiger Counter — sparse, very short grains, slight randomness.
        // Frequency knob is irrelevant for noise; the drone bed is a
        // separate low sine. Mostly demonstrates "rare events" feel.
        Preset("Geiger Counter (Granular)", .droneArtists,
               subtitle: "Granular · isolated clicks every ~1 s · soft sine bed · medium reverb",
               {
                   let rev = ReverbState(decaySec: 4.5, mix: 0.45)
                   return [
                    Voice(hz: 110.00, pan: 0.0, wave: .sine, amp: 0.40,
                          filter: FilterState(type: .lowpass, cutoffHz: 1200, q: 0.7),
                          reverb: rev),
                    Voice(hz: 220.00, pan: 0.0, wave: .granular, amp: 0.55,
                          filter: FilterState(type: .highpass, cutoffHz: 1400, q: 1.0),
                          reverb: rev,
                          grain: GrainState(sizeMs: 12, densityHz: 1.2, jitter: 0.85, panSpread: 0.85)),
                    Voice(hz: 0, pan: 0, wave: nil, amp: 0),
                    Voice(hz: 0, pan: 0, wave: nil, amp: 0)
                   ]
               }()),

        // Sparse Rain — distinct drops on a wide stereo field. Bigger
        // grains than Geiger so each event has a little body to it.
        Preset("Sparse Rain (Granular)", .droneArtists,
               subtitle: "Granular · soft droplets · open-room reverb · ambient sub-bass",
               {
                   let rev = ReverbState(decaySec: 6.0, mix: 0.55)
                   return [
                    Voice(hz:  55.00, pan: 0.0, wave: .sine,     amp: 0.30,
                          filter: FilterState(type: .lowpass, cutoffHz: 600, q: 0.7),
                          reverb: rev),
                    Voice(hz: 220.00, pan: -0.5, wave: .granular, amp: 0.45,
                          filter: FilterState(type: .bandpass, cutoffHz: 2000, q: 2.5),
                          reverb: rev,
                          grain: GrainState(sizeMs: 35, densityHz: 4, jitter: 0.75, panSpread: 0.7)),
                    Voice(hz: 220.00, pan:  0.5, wave: .granular, amp: 0.42,
                          startDelaySec: 8,
                          filter: FilterState(type: .bandpass, cutoffHz: 2200, q: 2.5),
                          reverb: rev,
                          grain: GrainState(sizeMs: 40, densityHz: 5, jitter: 0.85, panSpread: 0.8)),
                    Voice(hz: 0, pan: 0, wave: nil, amp: 0)
                   ]
               }()),

        // Rain Shower — dense, fast grains across the stereo field,
        // medium grain size for "pattering" texture. Slight pitch bed
        // for harmonic ground.
        Preset("Rain Shower (Granular)", .droneArtists,
               subtitle: "Granular · dense pattering · two stereo layers · airy reverb",
               {
                   let rev = ReverbState(decaySec: 3.5, mix: 0.40)
                   return [
                    Voice(hz: 110.00, pan: 0.0, wave: .triangle, amp: 0.25,
                          filter: FilterState(type: .lowpass, cutoffHz: 800, q: 0.7),
                          reverb: rev),
                    Voice(hz: 220.00, pan: -0.6, wave: .granular, amp: 0.50,
                          filter: FilterState(type: .highpass, cutoffHz: 1000, q: 1.0),
                          reverb: rev,
                          grain: GrainState(sizeMs: 25, densityHz: 28, jitter: 0.55, panSpread: 0.8)),
                    Voice(hz: 220.00, pan:  0.6, wave: .granular, amp: 0.48,
                          filter: FilterState(type: .highpass, cutoffHz: 1100, q: 1.0),
                          reverb: rev,
                          grain: GrainState(sizeMs: 22, densityHz: 32, jitter: 0.60, panSpread: 0.8)),
                    Voice(hz: 0, pan: 0, wave: nil, amp: 0)
                   ]
               }()),

        // Stone Tape — sparse low-frequency grains over a sub drone,
        // long reverb, very few grains per minute. Slowly emerging haunted
        // texture for deep meditation / sleep onset.
        Preset("Stone Tape (Granular)", .droneArtists,
               subtitle: "Granular · rare low grains · long-tail reverb · sub-bass drone bed",
               {
                   let rev = ReverbState(decaySec: 9.0, mix: 0.55)
                   return [
                    Voice(hz:  41.20, pan: 0.0, wave: .sine, amp: 0.35,
                          filter: FilterState(type: .lowpass, cutoffHz: 350, q: 0.7),
                          reverb: rev),
                    Voice(hz: 220.00, pan: 0.0, wave: .granular, amp: 0.55,
                          filter: FilterState(type: .lowpass, cutoffHz: 800, q: 1.5),
                          reverb: rev,
                          grain: GrainState(sizeMs: 180, densityHz: 0.7, jitter: 0.95, panSpread: 0.9)),
                    Voice(hz: 220.00, pan: 0.0, wave: .granular, amp: 0.30,
                          startDelaySec: 30,
                          filter: FilterState(type: .lowpass, cutoffHz: 500, q: 1.5),
                          reverb: rev,
                          grain: GrainState(sizeMs: 240, densityHz: 0.5, jitter: 0.95, panSpread: 0.85)),
                    Voice(hz: 0, pan: 0, wave: nil, amp: 0)
                   ]
               }()),

        // ─── T15: One new "granular + timed fade" piece per Drone Master ───
        // Each combines the new granular waveform with the per-voice timing
        // envelope (startDelaySec / playDurationSec) to evolve over a
        // session — voices enter and recede so the texture is never static.

        // Basinski II — Tape Decay Cycle. The user-requested follow-up:
        // a melodic triangle "loop" fades OUT over 4 min while two granular
        // crackle layers fade IN, dramatizing tape disintegration as time
        // advances. By the end the source is gone and only the decay remains.
        Preset("Basinski — Tape Decay Cycle", .droneArtists,
               subtitle: "Basinski · loop fades out as granular crackle takes over · 5-min arc",
               {
                   let rev = ReverbState(decaySec: 8.0, mix: 0.50)
                   return [
                    // The "loop" — triangle melody on a 1/4-note ping-pong
                    // delay. playDurationSec = 240 → fades out across 8 s
                    // starting at t = 240s (4 min). By 4:08 the source is
                    // silent; only the granular tape-decay remains.
                    Voice(hz: 261.63, pan: 0.0, wave: .triangle, amp: 0.55, drive: 1.5,
                          playDurationSec: 240,
                          filter: FilterState(type: .lowpass, cutoffHz: 1500, q: 1.0),
                          reverb: rev,
                          delay: DelayState(timeSec: 0.50, feedback: 0.65, mix: 0.40, mode: .pingPong, timing: .quarter),
                          lfos: [LfoState(shape: .sine, targets: [.amplitude], rateHz: 0.06, depth: 0.40), nil, nil, nil]),
                    // Sub bed — sine drone, always present, harmonic ground.
                    Voice(hz: 130.81, pan: 0.0, wave: .sine, amp: 0.35, reverb: rev),
                    // First decay layer — sparse granular crackle, enters at
                    // 30 s and fades in over 8 s. Medium grains so each
                    // event has tactile body. HP filter for "tape oxide" sheen.
                    Voice(hz: 220.00, pan: -0.4, wave: .granular, amp: 0.45,
                          startDelaySec: 30,
                          filter: FilterState(type: .highpass, cutoffHz: 1200, q: 1.2),
                          reverb: rev,
                          grain: GrainState(sizeMs: 45, densityHz: 2.5, jitter: 0.90, panSpread: 0.75)),
                    // Deeper decay layer — even sparser, longer grains, low
                    // BP filter. Enters at 120 s — by then the listener has
                    // settled into the loop and the gradual "wear" feels
                    // organic rather than imposed.
                    Voice(hz: 220.00, pan:  0.4, wave: .granular, amp: 0.50,
                          startDelaySec: 120,
                          filter: FilterState(type: .bandpass, cutoffHz: 800, q: 2.0),
                          reverb: rev,
                          grain: GrainState(sizeMs: 120, densityHz: 1.2, jitter: 0.95, panSpread: 0.85))
                   ]
               }()),

        // Oliveros II — Sonic Meditation (Granular Breath). Slow A drones
        // arrive in pairs (60s, 120s); granular pink-noise "breath" weaves
        // throughout but withdraws at 4 min, leaving the sustained drone.
        Preset("Oliveros — Sonic Meditation (Granular)", .droneArtists,
               subtitle: "Oliveros · A-drone pairs enter at 0 / 60 / 120 s · granular breath fades after 4 min",
               {
                   let rev = ReverbState(decaySec: 6.0, mix: 0.50)
                   return [
                    Voice(hz: 110.00, pan: -0.3, wave: .sine, amp: 0.50, reverb: rev),
                    Voice(hz: 220.00, pan:  0.3, wave: .sine, amp: 0.45,
                          startDelaySec: 60, reverb: rev),
                    Voice(hz:  55.00, pan: 0.0, wave: .sine, amp: 0.40,
                          startDelaySec: 120, reverb: rev),
                    // Granular "breath" — soft, medium-density, withdraws
                    // after 4 min so the final stretch is pure drone.
                    Voice(hz: 220.00, pan: 0.0, wave: .granular, amp: 0.30,
                          playDurationSec: 240,
                          filter: FilterState(type: .bandpass, cutoffHz: 1200, q: 1.5),
                          reverb: rev,
                          grain: GrainState(sizeMs: 80, densityHz: 6, jitter: 0.65, panSpread: 0.85))
                   ]
               }()),

        // Riley II — Granular Cascade. Triangle voices on staggered ping-pong
        // delays, granular sparkle that ARRIVES at 30 s and DEPARTS at 4 min.
        Preset("Riley — Granular Cascade", .droneArtists,
               subtitle: "Riley · triangle cascade · granular sparkle 0:30–4:00 · ping-pong delays",
               {
                   let rev = ReverbState(decaySec: 4.0, mix: 0.35)
                   let dly = DelayState(timeSec: 0.375, feedback: 0.55, mix: 0.55, mode: .pingPong, timing: .eighth)
                   return [
                    Voice(hz: 164.81, pan: -0.5, wave: .triangle, amp: 0.45,
                          reverb: rev, delay: dly),
                    Voice(hz: 246.94, pan:  0.5, wave: .triangle, amp: 0.40,
                          startDelaySec: 15, reverb: rev, delay: dly),
                    Voice(hz: 329.63, pan: -0.3, wave: .triangle, amp: 0.35,
                          startDelaySec: 45, reverb: rev, delay: dly),
                    // Granular sparkle — bell-high HP, medium density, fades
                    // out at 4 min so the ending is pure cascade.
                    Voice(hz: 220.00, pan: 0.0, wave: .granular, amp: 0.30,
                          startDelaySec: 30, playDurationSec: 210,
                          filter: FilterState(type: .highpass, cutoffHz: 2500, q: 1.5),
                          reverb: rev,
                          grain: GrainState(sizeMs: 18, densityHz: 14, jitter: 0.55, panSpread: 0.85))
                   ]
               }()),

        // Radigue II — Île Granular Beats. Two near-unison sines beat slowly
        // (0.4 Hz); very long granular grains drift in at 60 s and out at 6 min,
        // creating standing-wave clouds within the beating field.
        Preset("Radigue — Île Granular", .droneArtists,
               subtitle: "Radigue · 0.4 Hz binaural beat · granular clouds bloom 1:00–6:00",
               {
                   let rev = ReverbState(decaySec: 10.0, mix: 0.55)
                   return [
                    Voice(hz: 440.00, pan: -0.7, wave: .sine, amp: 0.45, reverb: rev),
                    Voice(hz: 440.40, pan:  0.7, wave: .sine, amp: 0.45, reverb: rev),
                    Voice(hz: 110.00, pan: 0.0, wave: .sine, amp: 0.35, reverb: rev,
                          lfos: [nil, LfoState(shape: .sine, targets: [.amplitude], rateHz: 0.04, depth: 0.30), nil, nil]),
                    // Granular cloud — very long grains, very sparse density;
                    // result is a slow "phantom note" texture inside the beat.
                    Voice(hz: 220.00, pan: 0.0, wave: .granular, amp: 0.40,
                          startDelaySec: 60, playDurationSec: 300,
                          filter: FilterState(type: .lowpass, cutoffHz: 1500, q: 1.0),
                          reverb: rev,
                          grain: GrainState(sizeMs: 350, densityHz: 0.8, jitter: 0.90, panSpread: 0.95))
                   ]
               }()),

        // Stars of the Lid II — Granular Halo. The classic orchestral pad
        // gets a granular shimmer that fades in over time, like dust caught
        // in a beam of light gradually revealing itself.
        Preset("Stars of the Lid — Granular Halo", .droneArtists,
               subtitle: "SOTL · orchestral pad · granular dust enters at 60 s and stays",
               {
                   let cho = ChorusState(rateHz: 0.4, depth: 0.6, width: 1.0, mix: 0.35)
                   let rev = ReverbState(decaySec: 6.5, mix: 0.50)
                   return [
                    Voice(hz: 220.00, pan: -0.3, wave: .sawtooth, amp: 0.40,
                          filter: FilterState(type: .lowpass, cutoffHz: 900, q: 0.8),
                          reverb: rev, chorus: cho),
                    Voice(hz: 329.63, pan:  0.3, wave: .sawtooth, amp: 0.35,
                          startDelaySec: 30,
                          filter: FilterState(type: .lowpass, cutoffHz: 900, q: 0.8),
                          reverb: rev, chorus: cho),
                    Voice(hz: 440.00, pan: 0.0, wave: .sawtooth, amp: 0.25,
                          startDelaySec: 90,
                          filter: FilterState(type: .lowpass, cutoffHz: 900, q: 0.8),
                          reverb: rev, chorus: cho),
                    // Granular shimmer — medium-dense, very HP, blooms at 60 s
                    // and stays for the full session.
                    Voice(hz: 220.00, pan: 0.0, wave: .granular, amp: 0.25,
                          startDelaySec: 60,
                          filter: FilterState(type: .highpass, cutoffHz: 2000, q: 1.0),
                          reverb: rev,
                          grain: GrainState(sizeMs: 60, densityHz: 18, jitter: 0.50, panSpread: 0.90))
                   ]
               }()),

        // Sunn O))) II — Granular Tar Pit. Heavy low drone + amp-cab grit;
        // a granular "amp deterioration" layer ramps up after 60 s, peaking
        // by minute 4 as if the amp is slowly self-destructing.
        Preset("Sunn O))) — Granular Tar Pit", .droneArtists,
               subtitle: "Sunn O))) · sub-bass + amp-decay granular crackle from 1:00 · drop master volume",
               {
                   let rev = ReverbState(decaySec: 5.0, mix: 0.30)
                   return [
                    Voice(hz: 41.20, pan: -0.4, wave: .sawtooth, amp: 0.75, drive: 6.5,
                          filter: FilterState(type: .lowpass, cutoffHz: 600, q: 1.5),
                          reverb: rev),
                    Voice(hz: 41.55, pan:  0.4, wave: .square, amp: 0.65, drive: 5.5,
                          filter: FilterState(type: .lowpass, cutoffHz: 700, q: 1.5),
                          reverb: rev),
                    Voice(hz: 220.00, pan: 0.0, wave: .granular, amp: 0.40,
                          startDelaySec: 60,
                          filter: FilterState(type: .highpass, cutoffHz: 1500, q: 1.2),
                          reverb: rev,
                          grain: GrainState(sizeMs: 30, densityHz: 8, jitter: 0.80, panSpread: 0.80)),
                    Voice(hz: 220.00, pan: 0.0, wave: .granular, amp: 0.35,
                          startDelaySec: 180,
                          filter: FilterState(type: .bandpass, cutoffHz: 2500, q: 2.0),
                          reverb: rev,
                          grain: GrainState(sizeMs: 18, densityHz: 22, jitter: 0.70, panSpread: 0.85))
                   ]
               }()),

        // Niblock II — Granular Cluster. Three microtonal sawtooths beat
        // against each other; a sparse granular voice peppers the cluster
        // with discrete events that fade in/out cyclically (amplitude LFO).
        Preset("Niblock — Granular Cluster", .droneArtists,
               subtitle: "Niblock · 3-voice microtonal cluster · granular peppering on slow LFO",
               {
                   let f = FilterState(type: .lowpass, cutoffHz: 1800, q: 0.7)
                   let r = ReverbState(decaySec: 3.5, mix: 0.25)
                   return [
                    Voice(hz: 220.00, pan: -0.7, wave: .sawtooth, amp: 0.40, filter: f, reverb: r),
                    Voice(hz: 222.30, pan:  0.0, wave: .sawtooth, amp: 0.40,
                          startDelaySec: 30, filter: f, reverb: r),
                    Voice(hz: 218.10, pan:  0.7, wave: .sawtooth, amp: 0.40,
                          startDelaySec: 60, filter: f, reverb: r),
                    Voice(hz: 220.00, pan: 0.0, wave: .granular, amp: 0.45,
                          startDelaySec: 90,
                          filter: FilterState(type: .bandpass, cutoffHz: 1500, q: 1.8),
                          reverb: r,
                          grain: GrainState(sizeMs: 28, densityHz: 5, jitter: 0.75, panSpread: 0.75),
                          lfos: [nil, LfoState(shape: .sine, targets: [.amplitude], rateHz: 0.05, depth: 0.6), nil, nil])
                   ]
               }()),

        // Palestine II — Granular Strumming. Just-intonation triangles +
        // granular bell-like grains that fade out at 3 min, leaving the
        // strumming triangles bare for the final third.
        Preset("Palestine — Granular Strumming", .droneArtists,
               subtitle: "Palestine · just-D triangles · granular bell grains depart at 3:00",
               {
                   let cho = ChorusState(rateHz: 0.45, depth: 0.65, width: 1.0, mix: 0.40)
                   let rev = ReverbState(decaySec: 5.5, mix: 0.40)
                   return [
                    Voice(hz:  73.42, pan: -0.2, wave: .triangle, amp: 0.55, reverb: rev, chorus: cho),
                    Voice(hz:  91.78, pan:  0.2, wave: .triangle, amp: 0.45,
                          startDelaySec: 20, reverb: rev, chorus: cho),
                    Voice(hz: 146.83, pan:  0.0, wave: .triangle, amp: 0.40,
                          startDelaySec: 50, reverb: rev, chorus: cho),
                    Voice(hz: 220.00, pan: 0.0, wave: .granular, amp: 0.30,
                          playDurationSec: 180,
                          filter: FilterState(type: .highpass, cutoffHz: 2500, q: 2.0),
                          reverb: rev,
                          grain: GrainState(sizeMs: 22, densityHz: 10, jitter: 0.60, panSpread: 0.80))
                   ]
               }()),

        // Wada II — Granular Bagpipe Breath. Bagpipe-style drone +
        // breathing granular wind that swells at 60 s and recedes at 5 min.
        Preset("Wada — Granular Bagpipe Breath", .droneArtists,
               subtitle: "Wada · just-intoned drone · granular wind enters 1:00, departs 5:00",
               {
                   let rev = ReverbState(decaySec: 5.0, mix: 0.35)
                   return [
                    Voice(hz: 146.83, pan: -0.4, wave: .sawtooth, amp: 0.50, drive: 2.0,
                          filter: FilterState(type: .lowpass, cutoffHz: 1500, q: 0.9),
                          reverb: rev),
                    Voice(hz: 220.00, pan:  0.4, wave: .sawtooth, amp: 0.45, drive: 2.0,
                          filter: FilterState(type: .lowpass, cutoffHz: 1500, q: 0.9),
                          reverb: rev),
                    Voice(hz: 293.66, pan: 0.0, wave: .sawtooth, amp: 0.30, drive: 1.8,
                          startDelaySec: 30,
                          filter: FilterState(type: .lowpass, cutoffHz: 1700, q: 0.9),
                          reverb: rev),
                    Voice(hz: 220.00, pan: 0.0, wave: .granular, amp: 0.35,
                          startDelaySec: 60, playDurationSec: 240,
                          filter: FilterState(type: .bandpass, cutoffHz: 1200, q: 1.5),
                          reverb: rev,
                          grain: GrainState(sizeMs: 100, densityHz: 12, jitter: 0.65, panSpread: 0.90))
                   ]
               }()),

        // Budd II — Granular Pearl Drops. Soft pad + sparse short granular
        // "pebbles" that gradually intensify over the first 4 min, then
        // recede in the final minute.
        Preset("Budd — Granular Pearl Drops", .droneArtists,
               subtitle: "Budd · soft pad · sparse granular pebbles · 5-min arc",
               {
                   let rev = ReverbState(decaySec: 7.0, mix: 0.55)
                   let cho = ChorusState(rateHz: 0.3, depth: 0.6, width: 1.0, mix: 0.30)
                   return [
                    Voice(hz: 174.61, pan: -0.3, wave: .sine, amp: 0.45,
                          filter: FilterState(type: .lowpass, cutoffHz: 1200, q: 0.7),
                          reverb: rev, chorus: cho),
                    Voice(hz: 261.63, pan:  0.3, wave: .sine, amp: 0.40,
                          startDelaySec: 30,
                          filter: FilterState(type: .lowpass, cutoffHz: 1200, q: 0.7),
                          reverb: rev, chorus: cho),
                    Voice(hz: 220.00, pan: -0.5, wave: .granular, amp: 0.35,
                          startDelaySec: 60, playDurationSec: 240,
                          filter: FilterState(type: .bandpass, cutoffHz: 2400, q: 2.5),
                          reverb: rev,
                          grain: GrainState(sizeMs: 14, densityHz: 3, jitter: 0.85, panSpread: 0.70)),
                    Voice(hz: 220.00, pan:  0.5, wave: .granular, amp: 0.35,
                          startDelaySec: 120, playDurationSec: 180,
                          filter: FilterState(type: .bandpass, cutoffHz: 3000, q: 2.5),
                          reverb: rev,
                          grain: GrainState(sizeMs: 12, densityHz: 4, jitter: 0.85, panSpread: 0.75))
                   ]
               }()),

        // Coltrane II — Spiritual Granular. Organ + 5th + granular
        // tabla-style sparse grains that bloom mid-piece then fade,
        // leaving the organ to carry the closing section.
        Preset("Coltrane — Spiritual Granular", .droneArtists,
               subtitle: "Coltrane · Leslie organ · granular tabla blooms 1:00–4:00",
               {
                   let cho = ChorusState(rateHz: 5.5, depth: 0.50, width: 1.0, mix: 0.40)
                   let rev = ReverbState(decaySec: 3.5, mix: 0.30)
                   return [
                    Voice(hz: 110.00, pan: -0.4, wave: .triangle, amp: 0.50, drive: 1.8,
                          filter: FilterState(type: .lowpass, cutoffHz: 2000, q: 1.0),
                          reverb: rev, chorus: cho),
                    Voice(hz: 165.00, pan:  0.4, wave: .triangle, amp: 0.45, drive: 1.8,
                          startDelaySec: 30,
                          filter: FilterState(type: .lowpass, cutoffHz: 2000, q: 1.0),
                          reverb: rev, chorus: cho),
                    Voice(hz: 220.00, pan: 0.0, wave: .granular, amp: 0.40,
                          startDelaySec: 60, playDurationSec: 180,
                          filter: FilterState(type: .bandpass, cutoffHz: 1400, q: 2.0),
                          reverb: rev,
                          grain: GrainState(sizeMs: 35, densityHz: 6, jitter: 0.70, panSpread: 0.75)),
                    Voice(hz: 55.00, pan: 0.0, wave: .sine, amp: 0.35, reverb: rev)
                   ]
               }()),

        // Earth II — Granular Tar. Doom B-drop + dense granular grit
        // that arrives at 90 s and lasts through to 6 min, then peels
        // back, leaving the doom dyad bare.
        Preset("Earth — Granular Tar", .droneArtists,
               subtitle: "Earth · low-B doom dyad · dense granular grit 1:30–6:00",
               {
                   let rev = ReverbState(decaySec: 5.0, mix: 0.30)
                   return [
                    Voice(hz: 30.87, pan: -0.5, wave: .sawtooth, amp: 0.70, drive: 5.0,
                          filter: FilterState(type: .lowpass, cutoffHz: 500, q: 1.8),
                          reverb: rev),
                    Voice(hz: 46.25, pan:  0.5, wave: .sawtooth, amp: 0.60, drive: 4.5,
                          startDelaySec: 30,
                          filter: FilterState(type: .lowpass, cutoffHz: 550, q: 1.8),
                          reverb: rev),
                    Voice(hz: 220.00, pan: 0.0, wave: .granular, amp: 0.45,
                          startDelaySec: 90, playDurationSec: 270,
                          filter: FilterState(type: .bandpass, cutoffHz: 1200, q: 1.8),
                          reverb: rev,
                          grain: GrainState(sizeMs: 22, densityHz: 16, jitter: 0.65, panSpread: 0.85)),
                    Voice(hz: 0, pan: 0, wave: nil, amp: 0)
                   ]
               }()),

        // Nurse With Wound II — Granular Tableau. Cross-osc FM weirdness
        // PLUS granular bursts that arrive in two waves (30 s and 150 s),
        // each gone within 90 s — feels like radio interference washing
        // through.
        Preset("Nurse With Wound — Granular Tableau", .droneArtists,
               subtitle: "NWW · FM weirdness · two granular interference waves at 0:30 + 2:30",
               {
                   let rev = ReverbState(decaySec: 4.0, mix: 0.35)
                   return [
                    Voice(hz: 110.00, pan: -0.5, wave: .square, amp: 0.40, drive: 2.5,
                          filter: FilterState(type: .lowpass, cutoffHz: 1800, q: 2.0),
                          reverb: rev,
                          fm: FMState(sourceIndex: 1, index: 80)),
                    Voice(hz: 165.00, pan:  0.5, wave: .sawtooth, amp: 0.35,
                          filter: FilterState(type: .bandpass, cutoffHz: 900, q: 3.0),
                          reverb: rev),
                    Voice(hz: 220.00, pan: -0.3, wave: .granular, amp: 0.40,
                          startDelaySec: 30, playDurationSec: 90,
                          filter: FilterState(type: .highpass, cutoffHz: 1800, q: 1.5),
                          reverb: rev,
                          grain: GrainState(sizeMs: 8, densityHz: 35, jitter: 0.50, panSpread: 0.85)),
                    Voice(hz: 220.00, pan:  0.3, wave: .granular, amp: 0.40,
                          startDelaySec: 150, playDurationSec: 90,
                          filter: FilterState(type: .bandpass, cutoffHz: 2200, q: 2.5),
                          reverb: rev,
                          grain: GrainState(sizeMs: 15, densityHz: 25, jitter: 0.85, panSpread: 0.90))
                   ]
               }()),

        // Haino II — Granular Spectral. D drone + HP granular shimmer
        // that swells, then a second deeper-pitched shimmer fades in over
        // it; the original shimmer fades out at 4 min so the closing minute
        // is the new layer alone over the drone.
        Preset("Haino — Granular Spectral", .droneArtists,
               subtitle: "Haino · D drone · two granular shimmer layers cross-fade 1:00–5:00",
               {
                   let cho = ChorusState(rateHz: 1.2, depth: 0.65, width: 1.0, mix: 0.45)
                   let rev = ReverbState(decaySec: 5.5, mix: 0.45)
                   return [
                    Voice(hz: 73.42, pan: 0.0, wave: .sawtooth, amp: 0.55, drive: 3.0,
                          filter: FilterState(type: .lowpass, cutoffHz: 800, q: 1.8),
                          reverb: rev, chorus: cho),
                    Voice(hz: 146.83, pan: 0.0, wave: .square, amp: 0.25,
                          startDelaySec: 30,
                          filter: FilterState(type: .lowpass, cutoffHz: 1200, q: 1.5),
                          reverb: rev),
                    Voice(hz: 220.00, pan: -0.6, wave: .granular, amp: 0.40,
                          startDelaySec: 60, playDurationSec: 180,
                          filter: FilterState(type: .highpass, cutoffHz: 2500, q: 1.8),
                          reverb: rev,
                          grain: GrainState(sizeMs: 25, densityHz: 16, jitter: 0.60, panSpread: 0.85)),
                    Voice(hz: 220.00, pan:  0.6, wave: .granular, amp: 0.35,
                          startDelaySec: 180,
                          filter: FilterState(type: .highpass, cutoffHz: 1500, q: 1.8),
                          reverb: rev,
                          grain: GrainState(sizeMs: 40, densityHz: 12, jitter: 0.70, panSpread: 0.85))
                   ]
               }()),

        // ─── T-Drift: 6 presets showcasing per-voice configurable drift ───
        //
        // The new pitchSemitones + pitchPeriodSec overrides on
        // DriftVoiceConfig let every voice cycle at its own amplitude and
        // tempo, independent of the others. These presets demonstrate the
        // range: from synchronous-but-phase-offset breathing (Tide Breath)
        // to deliberately polyrhythmic micro-shifts (Microtonal Dance).

        // Tide Breath — four sine voices in just-intonation A-major chord,
        // all on Ocean drift (±¼ semi, 90 s) but at different pitchPhases
        // (0 / 0.25 / 0.5 / 0.75). The chord breathes around its center
        // like a four-part choir inhaling out of sync.
        Preset("Tide Breath", .droneArtists,
               subtitle: "Just-A chord · four voices breathe out of sync · Ocean drift",
               {
                   let rev = ReverbState(decaySec: 8.0, mix: 0.50)
                   func ocean(phase: Double) -> DriftVoiceConfig {
                       DriftVoiceConfig(pitchMode: .ocean, pitchAmount: 1.0,
                                        pitchPhase: phase, panMode: .static,
                                        panAmount: 1.0, panPhase: 0,
                                        pitchSemitones: 0.25, pitchPeriodSec: 90)
                   }
                   return [
                    Voice(hz: 110.00, pan: -0.4, wave: .sine, amp: 0.45,
                          reverb: rev, drift: ocean(phase: 0.0)),
                    Voice(hz: 164.81, pan: -0.1, wave: .sine, amp: 0.40,   // E3
                          reverb: rev, drift: ocean(phase: 0.25)),
                    Voice(hz: 220.00, pan:  0.1, wave: .sine, amp: 0.40,
                          reverb: rev, drift: ocean(phase: 0.5)),
                    Voice(hz: 277.18, pan:  0.4, wave: .sine, amp: 0.35,   // C#4
                          reverb: rev, drift: ocean(phase: 0.75))
                   ]
               }()),

        // Detune Choir — four triangle voices in unison (220 Hz) each with
        // a slightly different wave drift period (45 / 60 / 75 / 90 s) at
        // ±¼ semi. The slow detuning creates a natural ensemble chorusing
        // that no static chorus FX can match — like a live human choir's
        // pitch wandering.
        Preset("Detune Choir", .droneArtists,
               subtitle: "Unison triangle quartet · independent ±¼-semi drift periods · natural chorusing",
               {
                   let rev = ReverbState(decaySec: 5.0, mix: 0.40)
                   func detune(period: Double, phase: Double) -> DriftVoiceConfig {
                       DriftVoiceConfig(pitchMode: .wave, pitchAmount: 1.0,
                                        pitchPhase: phase, panMode: .static,
                                        panAmount: 1.0, panPhase: 0,
                                        pitchSemitones: 0.25, pitchPeriodSec: period)
                   }
                   return [
                    Voice(hz: 220.00, pan: -0.7, wave: .triangle, amp: 0.40,
                          reverb: rev, drift: detune(period: 45, phase: 0.0)),
                    Voice(hz: 220.00, pan: -0.2, wave: .triangle, amp: 0.40,
                          reverb: rev, drift: detune(period: 60, phase: 0.3)),
                    Voice(hz: 220.00, pan:  0.2, wave: .triangle, amp: 0.40,
                          reverb: rev, drift: detune(period: 75, phase: 0.6)),
                    Voice(hz: 220.00, pan:  0.7, wave: .triangle, amp: 0.40,
                          reverb: rev, drift: detune(period: 90, phase: 0.1))
                   ]
               }()),

        // Quarter-Tone Cluster — Niblock-style sawtooth cluster but with
        // each voice slowly wandering ±½ semi at its own period. Static
        // beating + slow motion = the cluster is alive, never quite the
        // same two seconds in a row.
        Preset("Quarter-Tone Cluster", .droneArtists,
               subtitle: "4-voice sawtooth cluster · each voice wanders ±½ semi at its own tempo",
               {
                   let f = FilterState(type: .lowpass, cutoffHz: 2200, q: 0.7)
                   let rev = ReverbState(decaySec: 3.5, mix: 0.30)
                   func wander(period: Double) -> DriftVoiceConfig {
                       DriftVoiceConfig(pitchMode: .wave, pitchAmount: 1.0,
                                        pitchPhase: 0, panMode: .static,
                                        panAmount: 1.0, panPhase: 0,
                                        pitchSemitones: 0.5, pitchPeriodSec: period)
                   }
                   return [
                    Voice(hz: 220.00, pan: -0.8, wave: .sawtooth, amp: 0.40,
                          filter: f, reverb: rev, drift: wander(period: 60)),
                    Voice(hz: 222.30, pan: -0.3, wave: .sawtooth, amp: 0.40,
                          filter: f, reverb: rev, drift: wander(period: 95)),
                    Voice(hz: 218.10, pan:  0.3, wave: .sawtooth, amp: 0.40,
                          filter: f, reverb: rev, drift: wander(period: 130)),
                    Voice(hz: 221.40, pan:  0.8, wave: .sawtooth, amp: 0.40,
                          filter: f, reverb: rev, drift: wander(period: 175))
                   ]
               }()),

        // Pendulum Dawn — every voice swings left↔right (Pendulum pan)
        // while simultaneously breathing pitch on Ocean (±¼ semi, 120 s).
        // Wide stereo motion + subtle pitch wobble = expansive, dreamlike.
        Preset("Pendulum Dawn", .droneArtists,
               subtitle: "Voices swing wide L↔R while pitch breathes — Ocean + Pendulum",
               {
                   let rev = ReverbState(decaySec: 7.0, mix: 0.55)
                   let cho = ChorusState(rateHz: 0.4, depth: 0.5, width: 1.0, mix: 0.30)
                   func sweep(phase: Double, panPhase: Double) -> DriftVoiceConfig {
                       DriftVoiceConfig(pitchMode: .ocean, pitchAmount: 1.0,
                                        pitchPhase: phase, panMode: .pendulum,
                                        panAmount: 1.0, panPhase: panPhase,
                                        pitchSemitones: 0.25, pitchPeriodSec: 120)
                   }
                   return [
                    Voice(hz: 130.81, pan: 0.0, wave: .triangle, amp: 0.45,
                          reverb: rev, chorus: cho,
                          drift: sweep(phase: 0.0, panPhase: 0.0)),
                    Voice(hz: 196.00, pan: 0.0, wave: .triangle, amp: 0.40,
                          reverb: rev, chorus: cho,
                          drift: sweep(phase: 0.33, panPhase: 0.25)),
                    Voice(hz: 261.63, pan: 0.0, wave: .triangle, amp: 0.35,
                          reverb: rev, chorus: cho,
                          drift: sweep(phase: 0.66, panPhase: 0.5)),
                    Voice(hz: 392.00, pan: 0.0, wave: .sine, amp: 0.25,
                          reverb: rev, chorus: cho,
                          drift: sweep(phase: 0.5, panPhase: 0.75))
                   ]
               }()),

        // Tibetan Bowl Cycle — center pitch with two voices wobbling ±½
        // semi at a long 180 s period, mimicking the natural pitch wander
        // of a struck singing bowl as its overtones interact. Long reverb
        // for the room-tail.
        Preset("Tibetan Bowl Cycle", .droneArtists,
               subtitle: "Bowl-like wobble · ±½ semi every 3 min · long-tail reverb",
               {
                   let rev = ReverbState(decaySec: 9.0, mix: 0.60)
                   func wobble(phase: Double) -> DriftVoiceConfig {
                       DriftVoiceConfig(pitchMode: .wave, pitchAmount: 1.0,
                                        pitchPhase: phase, panMode: .static,
                                        panAmount: 1.0, panPhase: 0,
                                        pitchSemitones: 0.5, pitchPeriodSec: 180)
                   }
                   return [
                    // Fundamental
                    Voice(hz: 146.83, pan: 0.0, wave: .triangle, amp: 0.55,
                          filter: FilterState(type: .lowpass, cutoffHz: 1800, q: 0.9),
                          reverb: rev,
                          drift: wobble(phase: 0.0)),
                    // 5th — wobbles out of sync
                    Voice(hz: 220.00, pan: -0.4, wave: .sine, amp: 0.40,
                          reverb: rev,
                          drift: wobble(phase: 0.4)),
                    // Octave shimmer
                    Voice(hz: 293.66, pan:  0.4, wave: .sine, amp: 0.30,
                          startDelaySec: 30,
                          reverb: rev,
                          drift: wobble(phase: 0.7)),
                    // High partial — barely audible, adds bell sparkle
                    Voice(hz: 587.33, pan: 0.0, wave: .sine, amp: 0.15,
                          startDelaySec: 60,
                          filter: FilterState(type: .highpass, cutoffHz: 400, q: 0.7),
                          reverb: rev,
                          drift: wobble(phase: 0.2))
                   ]
               }()),

        // Microtonal Dance — polyrhythmic showcase. Each voice has a
        // different drift period: 30 / 60 / 120 / 240 s. The voices align
        // every 4 minutes, drift apart again. Mathematical, almost
        // generative-feeling.
        Preset("Microtonal Dance", .droneArtists,
               subtitle: "Polyrhythmic drift · periods 30/60/120/240 s · aligns every 4 min",
               {
                   let rev = ReverbState(decaySec: 5.0, mix: 0.40)
                   func dance(amount: Double, period: Double) -> DriftVoiceConfig {
                       DriftVoiceConfig(pitchMode: .wave, pitchAmount: 1.0,
                                        pitchPhase: 0, panMode: .static,
                                        panAmount: 1.0, panPhase: 0,
                                        pitchSemitones: amount, pitchPeriodSec: period)
                   }
                   return [
                    Voice(hz: 220.00, pan: -0.7, wave: .triangle, amp: 0.40,
                          reverb: rev, drift: dance(amount: 1.0, period: 30)),
                    Voice(hz: 277.18, pan: -0.2, wave: .triangle, amp: 0.40,
                          reverb: rev, drift: dance(amount: 0.5, period: 60)),
                    Voice(hz: 329.63, pan:  0.2, wave: .triangle, amp: 0.40,
                          reverb: rev, drift: dance(amount: 0.25, period: 120)),
                    Voice(hz: 110.00, pan: 0.0, wave: .sine, amp: 0.35,
                          reverb: rev, drift: dance(amount: 2.0, period: 240))
                   ]
               }()),

        // v1.1 quantize-to-scale showcases. Both rely on the CURRENT
        // CHORD selection (try C Minor 7, Bb Maj9, A Phrygian…). With
        // quantize on, the pitch LFO widens to ±1 octave so the snap
        // can actually reach every chord tone in the 2-octave snap
        // cache — turning continuous LFO motion into arpeggios.

        // Chord Arpeggio — single triangle voice with a slow S&H LFO
        // on pitch, fully quantized. Triangle wave through gentle LP
        // gives a soft mallet-like timbre. One chord tone every ~2 sec
        // chosen randomly from the current chord, with a long reverb
        // tail so notes overlap into a chord cloud.
        Preset("Chord Arpeggio", .droneArtists,
               subtitle: "Solo voice · S&H pitch quantized to current chord · slow random walk",
               {
                   let rev = ReverbState(decaySec: 7.0, mix: 0.55)
                   let f   = FilterState(type: .lowpass, cutoffHz: 2400, q: 0.8)
                   let sh: [LfoState?] = [
                       LfoState(shape: .sampleAndHold, targets: [.pitch],
                                rateHz: 0.5, depth: 1.0),
                       nil, nil, nil
                   ]
                   let drift = DriftVoiceConfig(
                       pitchMode: .static, panMode: .static,
                       quantizeToScale: true)
                   return [
                    Voice(hz: 220.00, pan: 0.0, wave: .triangle, amp: 0.50,
                          filter: f, reverb: rev, lfos: sh, drift: drift),
                    silent, silent, silent
                   ]
               }()),

        // Quantum Bells — 4 voices, each with a fast S&H pitch LFO
        // (rates 2 / 3 / 5 / 7 Hz — coprime so they never re-align)
        // all quantized to the current chord. Result is a sparkling
        // 4-part stochastic arpeggio across ±1 octave. Long reverb +
        // gentle low-pass keep it from feeling brittle. Try over
        // C Minor 7 or Maj9 chords.
        Preset("Quantum Bells", .droneArtists,
               subtitle: "4 voices · coprime S&H rates · quantized arpeggio cloud",
               {
                   let rev = ReverbState(decaySec: 8.0, mix: 0.55)
                   let f   = FilterState(type: .lowpass, cutoffHz: 3200, q: 0.6)
                   func bellLFO(rate: Double) -> [LfoState?] {
                       [LfoState(shape: .sampleAndHold, targets: [.pitch],
                                 rateHz: rate, depth: 1.0),
                        nil, nil, nil]
                   }
                   let drift = DriftVoiceConfig(
                       pitchMode: .static, panMode: .static,
                       quantizeToScale: true)
                   return [
                    Voice(hz: 220.00, pan: -0.7, wave: .triangle, amp: 0.32,
                          filter: f, reverb: rev,
                          lfos: bellLFO(rate: 2.0), drift: drift),
                    Voice(hz: 277.18, pan: -0.2, wave: .sine, amp: 0.32,
                          filter: f, reverb: rev,
                          lfos: bellLFO(rate: 3.0), drift: drift),
                    Voice(hz: 329.63, pan:  0.2, wave: .triangle, amp: 0.30,
                          filter: f, reverb: rev,
                          lfos: bellLFO(rate: 5.0), drift: drift),
                    Voice(hz: 440.00, pan:  0.7, wave: .sine, amp: 0.28,
                          filter: f, reverb: rev,
                          lfos: bellLFO(rate: 7.0), drift: drift)
                   ]
               }())
    ]

    static let byCategory: [Category: [Preset]] = {
        var dict: [Category: [Preset]] = [:]
        for p in all {
            dict[p.category, default: []].append(p)
        }
        return dict
    }()
}
