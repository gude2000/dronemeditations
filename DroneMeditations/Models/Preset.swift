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
        let filter: FilterState?
        let reverb: ReverbState?
        let delay: DelayState?
        let chorus: ChorusState?
        let fm: FMState?
        /// Per-LFO overrides. nil entries (or fewer than 4) leave the
        /// corresponding LFO alone; non-nil entries replace it.
        let lfos: [LfoState?]?
        let drift: DriftVoiceConfig?

        init(hz: Double, pan: Double = 0,
             wave: Waveform? = nil, amp: Double? = nil,
             drive: Double? = nil,
             startDelaySec: Double? = nil,
             playDurationSec: Double? = nil,
             filter: FilterState? = nil,
             reverb: ReverbState? = nil,
             delay: DelayState? = nil,
             chorus: ChorusState? = nil,
             fm: FMState? = nil,
             lfos: [LfoState?]? = nil,
             drift: DriftVoiceConfig? = nil) {
            self.hz = hz; self.pan = pan
            self.wave = wave; self.amp = amp
            self.drive = drive
            self.startDelaySec = startDelaySec
            self.playDurationSec = playDurationSec
            self.filter = filter; self.reverb = reverb
            self.delay = delay; self.chorus = chorus
            self.fm = fm; self.lfos = lfos; self.drift = drift
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
                      lfos: [LfoState(shape: .sine, target: .amplitude, rateHz: 0.07, depth: 0.30), nil, nil, nil]),
                Voice(hz: 220.12,  pan:  0.4, wave: .sine, amp: 0.50,
                      startDelaySec: 60,
                      reverb: ReverbState(decaySec: 8.0, mix: 0.40),
                      lfos: [LfoState(shape: .sine, target: .amplitude, rateHz: 0.09, depth: 0.35), nil, nil, nil]),
                Voice(hz: 329.85,  pan: -0.2, wave: .sine, amp: 0.42,
                      startDelaySec: 120,
                      reverb: ReverbState(decaySec: 8.0, mix: 0.40),
                      lfos: [LfoState(shape: .sine, target: .amplitude, rateHz: 0.06, depth: 0.40), nil, nil, nil]),
                Voice(hz: 440.00,  pan:  0.2, wave: .sine, amp: 0.38,
                      startDelaySec: 240,
                      reverb: ReverbState(decaySec: 8.0, mix: 0.40),
                      lfos: [LfoState(shape: .sine, target: .amplitude, rateHz: 0.08, depth: 0.35), nil, nil, nil])
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
                       [nil, LfoState(shape: .sine, target: .cutoff, rateHz: rate, depth: 0.35), nil, nil]
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
                   let trem: [LfoState?] = [LfoState(shape: .square, target: .amplitude, rateHz: 0.7, depth: 0.30), nil, nil, nil]
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
                            LfoState(shape: .sine, target: .amplitude, rateHz: 0.08, depth: 0.45),
                            LfoState(shape: .sine, target: .cutoff,    rateHz: 0.03, depth: 0.55),
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
                          lfos: [LfoState(shape: .sine, target: .amplitude, rateHz: 0.08, depth: 0.55), nil, nil, nil])
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
                   let wobble: [LfoState?] = [nil, nil, nil, LfoState(shape: .sine, target: .pitch, rateHz: 5.0, depth: 0.02)]
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
                       [LfoState(shape: .sine, target: .amplitude, rateHz: rate, depth: 0.40), nil, nil, nil]
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
                   let leslie: [LfoState?] = [nil, nil, LfoState(shape: .sine, target: .pan, rateHz: 0.8, depth: 0.40), nil]
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
                          lfos: [nil, LfoState(shape: .sampleAndHold, target: .cutoff, rateHz: 0.15, depth: 0.55), nil, nil]),
                    Voice(hz: 311.13, pan: -0.3, wave: .sine,     amp: 0.30, reverb: rev),
                    // White noise w/ S&H amp LFO + wandering BP — intermittent
                    // texture bursts at irregular intervals, very NWW.
                    Voice(hz: 220.00, pan: 0.3, wave: .whiteNoise, amp: 0.30,
                          filter: FilterState(type: .bandpass, cutoffHz: 1200, q: 4.0),
                          reverb: rev,
                          lfos: [
                            LfoState(shape: .sampleAndHold, target: .amplitude, rateHz: 0.30, depth: 0.80),
                            LfoState(shape: .sine, target: .cutoff, rateHz: 0.10, depth: 0.50),
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
                       [nil, nil, nil, LfoState(shape: .sine, target: .pitch, rateHz: rate, depth: 0.05)]
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
