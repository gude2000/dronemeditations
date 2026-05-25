// Music theory layer — ported from the native Swift sources.
// Pure data + math. No browser APIs.

// ────────────────────────────────────────────────────────────
// Waveforms — names match Web Audio's OscillatorType strings.
// ────────────────────────────────────────────────────────────
export const WAVEFORMS = [
  { id: "sine",     name: "Sine",     symbol: "sine" },
  { id: "triangle", name: "Triangle", symbol: "triangle" },
  { id: "sawtooth", name: "Saw",      symbol: "saw" },
  { id: "square",   name: "Square",   symbol: "square" },
  { id: "sample",   name: "Sample",   symbol: "sample" }
];

/// Reference frequency used as the "unity pitch" anchor when a sample is loaded.
/// At this frequency the sample plays at 1.0× its native rate.
export const SAMPLE_REFERENCE_HZ = 220;

// ────────────────────────────────────────────────────────────
// Pitch classes (C, C♯, D, ..., B) and helpers.
// ────────────────────────────────────────────────────────────
export const PITCH_CLASSES = [
  { id: 0,  name: "C"  },
  { id: 1,  name: "C♯" },
  { id: 2,  name: "D"  },
  { id: 3,  name: "D♯" },
  { id: 4,  name: "E"  },
  { id: 5,  name: "F"  },
  { id: 6,  name: "F♯" },
  { id: 7,  name: "G"  },
  { id: 8,  name: "G♯" },
  { id: 9,  name: "A"  },
  { id: 10, name: "A♯" },
  { id: 11, name: "B"  }
];

/** MIDI note number for (pitchClassId, octave). C4 = 60, A4 = 69. */
export function midiNote(pcId, octave) {
  return (octave + 1) * 12 + pcId;
}

/** Frequency in 12-TET with A4 = 440. */
export function pitchToFrequency(pcId, octave, refA4 = 440) {
  const semitonesAboveA4 = midiNote(pcId, octave) - 69;
  return refA4 * Math.pow(2, semitonesAboveA4 / 12);
}

// ────────────────────────────────────────────────────────────
// Tuning systems — each one snaps a target cents value to its grid.
// ────────────────────────────────────────────────────────────
const PHI = (1 + Math.sqrt(5)) / 2;
const PHI_OCTAVE_CENTS = Math.log2(PHI) * 1200;

const JUST_CENTS = [0, 111.731, 203.910, 315.641, 386.314, 498.045, 582.512, 701.955, 813.686, 884.359, 1017.596, 1088.269];
const PYTHAG_CENTS = [0, 113.685, 203.910, 294.135, 407.820, 498.045, 611.730, 701.955, 792.180, 905.865, 996.090, 1109.775];

// Lou Harrison "Free-Style" JI — heptatonic 5-limit + 7th-partial scale he
// used across his gamelan + chamber works. Ratios 1/1, 9/8, 5/4, 4/3, 3/2,
// 5/3, 7/4, 2/1 → cents below.
const HARRISON_CENTS = [0, 203.910, 386.314, 498.045, 701.955, 884.359, 968.826];

// Harry Partch's 43-tone JI scale, cents from 1/1. Builds a dense
// microtonal lattice in a single octave; every chord voice snaps to the
// nearest of these 43 degrees per octave.
const PARTCH_43 = [
  0, 21.51, 53.27, 84.47, 111.73, 150.64, 165.00, 182.40, 203.91,
  231.17, 266.87, 294.13, 315.64, 347.41, 386.31, 417.51, 435.08,
  470.78, 498.04, 519.55, 551.32, 582.51, 617.49, 648.68, 680.45,
  701.96, 729.22, 764.92, 782.49, 813.69, 852.59, 884.36, 905.87,
  933.13, 968.83, 996.09, 1017.60, 1034.99, 1049.36, 1088.27,
  1115.53, 1146.73, 1178.49
];

// Wendy Carlos "Alpha/Beta/Gamma" — non-octave-repeating equal divisions
// designed to better fit triadic harmony than 12-TET:
//   α = 78.0 cents/step
//   β = 63.8 cents/step
//   γ = 35.1 cents/step
// snapEqual already does the right thing — these scales just don't wrap
// at the octave, so consonant intervals land in surprising places.
const CARLOS_ALPHA_STEP = 78.0;
const CARLOS_BETA_STEP  = 63.8;
const CARLOS_GAMMA_STEP = 35.1;

function snapEqual(cents, step) {
  return Math.round(cents / step) * step;
}

function snapTable(cents, table, periodCents) {
  const octaves = Math.floor(cents / periodCents);
  const reduced = cents - octaves * periodCents;
  let best = table[0];
  let bestDist = Math.abs(reduced - table[0]);
  for (let i = 1; i < table.length; i++) {
    const d = Math.abs(reduced - table[i]);
    if (d < bestDist) { bestDist = d; best = table[i]; }
  }
  // Allow snapping to the period boundary as a degree too.
  const dPeriod = Math.abs(reduced - periodCents);
  if (dPeriod < bestDist) { best = periodCents; }
  return octaves * periodCents + best;
}

export const TUNING_SYSTEMS = [
  { id: "equal12",        name: "12-TET",         snap: (c) => snapEqual(c, 100) },
  { id: "equal24",        name: "24-TET",         snap: (c) => snapEqual(c, 50) },
  { id: "equal72",        name: "72-TET",         snap: (c) => snapEqual(c, 1200 / 72) },
  { id: "wholeTone",      name: "Whole Tone",     snap: (c) => snapEqual(c, 200) },
  { id: "justIntonation", name: "Just",           snap: (c) => snapTable(c, JUST_CENTS, 1200) },
  { id: "pythagorean",    name: "Pythagorean",    snap: (c) => snapTable(c, PYTHAG_CENTS, 1200) },
  { id: "harrisonFreeJI", name: "Harrison JI",    snap: (c) => snapTable(c, HARRISON_CENTS, 1200) },
  { id: "partch43",       name: "Partch 43-tone", snap: (c) => snapTable(c, PARTCH_43, 1200) },
  { id: "carlosAlpha",    name: "Carlos α",       snap: (c) => snapEqual(c, CARLOS_ALPHA_STEP) },
  { id: "carlosBeta",     name: "Carlos β",       snap: (c) => snapEqual(c, CARLOS_BETA_STEP) },
  { id: "carlosGamma",    name: "Carlos γ",       snap: (c) => snapEqual(c, CARLOS_GAMMA_STEP) },
  { id: "phi",            name: "Phi (φ)",        snap: (c) => snapEqual(c, PHI_OCTAVE_CENTS / 13) }
];

/** Compute the frequency for a target interval (cents) above a root, snapped to tuning. */
export function snappedFrequency(tuningId, rootHz, cents) {
  const t = TUNING_SYSTEMS.find((s) => s.id === tuningId) || TUNING_SYSTEMS[0];
  return rootHz * Math.pow(2, t.snap(cents) / 1200);
}

// ────────────────────────────────────────────────────────────
// Chord catalog — each chord has 4 voices defined as cents from root.
// ────────────────────────────────────────────────────────────
const semis = (n) => n * 100;
const PHI_STEP = PHI_OCTAVE_CENTS / 13;

export const CHORD_CATEGORIES = [
  "Triads & 7ths",
  "Extensions",
  "Symmetric",
  "Quartal & Open",
  "Microtonal"
];

export const CHORDS = [
  // Triads & 7ths
  { id: "maj",     name: "Major",            category: "Triads & 7ths", cents: [semis(0), semis(4),  semis(7),  semis(12)] },
  { id: "min",     name: "Minor",            category: "Triads & 7ths", cents: [semis(0), semis(3),  semis(7),  semis(12)] },
  { id: "dim",     name: "Diminished",       category: "Triads & 7ths", cents: [semis(0), semis(3),  semis(6),  semis(12)] },
  { id: "aug",     name: "Augmented",        category: "Triads & 7ths", cents: [semis(0), semis(4),  semis(8),  semis(12)] },
  { id: "sus2",    name: "Sus2",             category: "Triads & 7ths", cents: [semis(0), semis(2),  semis(7),  semis(12)] },
  { id: "sus4",    name: "Sus4",             category: "Triads & 7ths", cents: [semis(0), semis(5),  semis(7),  semis(12)] },
  { id: "maj7",    name: "Major 7",          category: "Triads & 7ths", cents: [semis(0), semis(4),  semis(7),  semis(11)] },
  { id: "min7",    name: "Minor 7",          category: "Triads & 7ths", cents: [semis(0), semis(3),  semis(7),  semis(10)] },
  { id: "dom7",    name: "Dominant 7",       category: "Triads & 7ths", cents: [semis(0), semis(4),  semis(7),  semis(10)] },
  { id: "dim7",    name: "Diminished 7",     category: "Triads & 7ths", cents: [semis(0), semis(3),  semis(6),  semis(9)]  },
  { id: "m7b5",    name: "Half-Dim (m7♭5)",  category: "Triads & 7ths", cents: [semis(0), semis(3),  semis(6),  semis(10)] },
  { id: "mMaj7",   name: "Minor-Maj 7",      category: "Triads & 7ths", cents: [semis(0), semis(3),  semis(7),  semis(11)] },
  { id: "aug7",    name: "Augmented 7",      category: "Triads & 7ths", cents: [semis(0), semis(4),  semis(8),  semis(10)] },

  // Extensions
  { id: "add9",    name: "Add 9",            category: "Extensions",    cents: [semis(0), semis(4),  semis(7),  semis(14)] },
  { id: "min_add9",name: "Minor Add 9",      category: "Extensions",    cents: [semis(0), semis(3),  semis(7),  semis(14)] },
  { id: "6",       name: "6 chord",          category: "Extensions",    cents: [semis(0), semis(4),  semis(7),  semis(9)]  },
  { id: "min6",    name: "Minor 6",          category: "Extensions",    cents: [semis(0), semis(3),  semis(7),  semis(9)]  },
  { id: "maj9no5", name: "Major 9 (no 5)",   category: "Extensions",    cents: [semis(0), semis(4),  semis(11), semis(14)] },
  { id: "7sus4",   name: "7 sus4",           category: "Extensions",    cents: [semis(0), semis(5),  semis(7),  semis(10)] },

  // Symmetric
  { id: "wt",      name: "Whole-Tone",       category: "Symmetric",     cents: [semis(0), semis(2),  semis(4),  semis(6)]  },
  { id: "tt_stk",  name: "Tritone Stack",    category: "Symmetric",     cents: [semis(0), semis(6),  semis(12), semis(18)] },
  { id: "min3_stk",name: "Minor 3rd Stack",  category: "Symmetric",     cents: [semis(0), semis(3),  semis(6),  semis(9)]  },
  { id: "maj3_stk",name: "Major 3rd Stack",  category: "Symmetric",     cents: [semis(0), semis(4),  semis(8),  semis(12)] },
  { id: "chrom",   name: "Chromatic Cluster",category: "Symmetric",     cents: [semis(0), semis(1),  semis(2),  semis(3)]  },

  // Quartal & Open
  { id: "quartal", name: "Quartal",          category: "Quartal & Open",cents: [semis(0), semis(5),  semis(10), semis(15)] },
  { id: "quintal", name: "Quintal",          category: "Quartal & Open",cents: [semis(0), semis(7),  semis(14), semis(21)] },
  { id: "open5",   name: "Open Fifth",       category: "Quartal & Open",cents: [semis(0), semis(7),  semis(12), semis(19)] },
  { id: "octs",    name: "Octaves",          category: "Quartal & Open",cents: [semis(0), semis(12), semis(24), semis(36)] },
  { id: "drone",   name: "Power Drone",      category: "Quartal & Open",cents: [semis(0), semis(7),  semis(12), semis(7)]  },

  // Microtonal
  { id: "phi_step",  name: "Phi Steps",          category: "Microtonal", cents: [0, PHI_STEP, PHI_STEP * 2, PHI_STEP * 3] },
  { id: "phi_open",  name: "Phi Open",           category: "Microtonal", cents: [0, PHI_STEP * 2, PHI_STEP * 4, PHI_STEP * 6] },
  { id: "phi_ratio", name: "Phi Ratio Stack",    category: "Microtonal", cents: [0, 833.09, 1666.18, 2499.27] },
  { id: "tet72_neu", name: "72-TET Neutral",     category: "Microtonal", cents: [0, 350.0, 700.0, 1050.0] },
  { id: "qt_cluster",name: "Quartertone Cluster",category: "Microtonal", cents: [0, 50.0, 100.0, 150.0] },
  { id: "bp_triad",  name: "Bohlen-Pierce Triad",category: "Microtonal", cents: [0, 854.0, 1466.0, 1902.0] },
  { id: "harmonic",  name: "7-Limit Harmonic",   category: "Microtonal", cents: [0, 386.31, 701.96, 968.83] }
];

/** Resolve a chord at a given root + tuning to 4 frequencies. */
export function chordFrequencies(chord, rootHz, tuningId) {
  return chord.cents.map((c) => snappedFrequency(tuningId, rootHz, c));
}

// ────────────────────────────────────────────────────────────
// Presets — binaural, Solfeggio, natural resonance.
// Each preset is exactly 4 voices: { hz, pan } where pan ∈ [-1, +1].
// Silent slots default to a quiet voice that gets muted by the engine.
// ────────────────────────────────────────────────────────────
const L = (hz) => ({ hz, pan: -1.0 });
const R = (hz) => ({ hz, pan: +1.0 });
const C = (hz) => ({ hz, pan: 0.0 });
const SILENT = { hz: 110, pan: 0.0, _silent: true };

/// Rich voice spec for character-driven presets (Drone Artists category, etc.).
/// All fields except `hz` are optional — applyPreset only pushes the fields
/// that are defined, so other voice state survives untouched. Use this helper
/// when a preset's *sound* (waveform, filter, FX) is part of its identity.
const V = (spec) => ({ hz: spec.hz, pan: spec.pan ?? 0, ...spec });

export const PRESET_CATEGORIES = [
  "Drone Artists",
  "Binaural — 2 tone",
  "Binaural — 3 tone",
  "Binaural — 4 tone",
  "Natural Resonance",
  "Cymatics",
  "Solfeggio",
  "Mystic & Composers"
];

export const PRESETS = [
  // 2-tone binaural
  { id: "delta_4",  name: "Delta 4 Hz (Deep Sleep)",      category: "Binaural — 2 tone", sub: "200 L / 204 R",      voices: [L(200), R(204), SILENT, SILENT] },
  { id: "theta_6",  name: "Theta 6 Hz (Meditation)",      category: "Binaural — 2 tone", sub: "200 L / 206 R",      voices: [L(200), R(206), SILENT, SILENT] },
  { id: "schumann", name: "Schumann 7.83 Hz",             category: "Binaural — 2 tone", sub: "100 L / 107.83 R",   voices: [L(100), R(107.83), SILENT, SILENT] },
  { id: "alpha_10", name: "Alpha 10 Hz (Relaxed Focus)",  category: "Binaural — 2 tone", sub: "210 L / 220 R",      voices: [L(210), R(220), SILENT, SILENT] },
  { id: "beta_18",  name: "Beta 18 Hz (Alert)",           category: "Binaural — 2 tone", sub: "210 L / 228 R",      voices: [L(210), R(228), SILENT, SILENT] },
  { id: "gamma_40", name: "Gamma 40 Hz (Insight)",        category: "Binaural — 2 tone", sub: "200 L / 240 R",      voices: [L(200), R(240), SILENT, SILENT] },

  // 3-tone binaural
  { id: "theta_tri",  name: "Theta Triad",                category: "Binaural — 3 tone", sub: "Schumann + theta drone",     voices: [L(100), R(107.83), C(50),  SILENT] },
  { id: "alpha_fifth",name: "Alpha + 5th",                category: "Binaural — 3 tone", sub: "10 Hz beat + perfect 5th",   voices: [L(220), R(230),    C(330), SILENT] },
  { id: "gamma_layer",name: "Gamma Layered",              category: "Binaural — 3 tone", sub: "40 Hz with octave bedding",  voices: [L(200), R(240),    C(100), SILENT] },

  // 4-tone binaural
  { id: "dual_theta",  name: "Dual Theta",                category: "Binaural — 4 tone", sub: "6 Hz + 4 Hz cross-beat",      voices: [L(200), R(206), L(330), R(334)] },
  { id: "alpha_gamma", name: "Alpha + Gamma",             category: "Binaural — 4 tone", sub: "10 Hz and 40 Hz coexisting",  voices: [L(220), R(230), L(300), R(340)] },
  { id: "phi_field",   name: "Phi-Tuned Field",           category: "Binaural — 4 tone", sub: "Golden-ratio carriers, theta beat", voices: [L(132), R(138), L(213.5), R(219.5)] },
  { id: "schumann_x",  name: "Complex Schumann",          category: "Binaural — 4 tone", sub: "7.83 + 14.3 + 20.8 layers",   voices: [L(100), R(107.83), L(200), R(214.3)] },

  // Natural resonance
  { id: "earth",  name: "Earth (Schumann fundamental)",   category: "Natural Resonance", sub: "7.83 Hz",                 voices: [L(100), R(107.83), C(50), SILENT] },
  { id: "c_phi",  name: "C-φ (Jose/Alex)",                category: "Natural Resonance", sub: "266.67 Hz — the icon-generator frequency", voices: [L(133.33), C(266.67), C(266.67), R(533.33)] },
  { id: "phi_aug", name: "Jose & Alex Phi Augmented Chord", category: "Natural Resonance", sub: "C–E–G♯ tuned to 1 : √φ : φ — the Webb triangle", voices: [L(164.81), C(266.67), R(209.64), SILENT] },
  { id: "sable",   name: "Sable's Chord",                    category: "Natural Resonance", sub: "φ-tuned C-E-G♯ on the φ-tuned C — 1 : √φ : φ", voices: [L(266.67), C(339.20), R(431.36), SILENT] },
  { id: "om",     name: "OM 136.1 Hz",                    category: "Natural Resonance", sub: "Tuned to Earth's year",   voices: [C(136.1), C(272.2), L(204.15), R(204.15)] },
  { id: "moon",   name: "Moon 210.42 Hz",                 category: "Natural Resonance", sub: "Cosmic-octave moon orbit",voices: [C(210.42), L(105.21), R(315.63), C(420.84)] },
  { id: "sun",    name: "Sun 126.22 Hz",                  category: "Natural Resonance", sub: "Cosmic-octave solar",     voices: [C(126.22), L(63.11), R(189.33), C(252.44)] },

  // Cymatics — frequency combinations known for highly symmetric / striking nodal patterns.
  { id: "hypogeum",        name: "Hypogeum 111 Hz",          category: "Cymatics", sub: "Maltese megalithic chamber — single-tone radial symmetry", voices: [L(55.5), C(111), R(222), SILENT] },
  { id: "harmonic_series", name: "Harmonic Series 1:2:3:4",  category: "Cymatics", sub: "100·200·300·400 Hz — clean orthogonal grid", voices: [L(100), C(200), C(300), R(400)] },
  { id: "just_major",      name: "Just Major Triad 4:5:6",   category: "Cymatics", sub: "C-E-G+C in pure intonation — 5-fold floral pattern", voices: [L(264), C(330), C(396), R(528)] },
  { id: "octave_stack",    name: "Octave Stack 1:2:4:8",     category: "Cymatics", sub: "75·150·300·600 Hz — pure-doubling lattice", voices: [L(75), C(150), C(300), R(600)] },
  { id: "fifths_stack",    name: "Perfect Fifths 2:3:9/2:27/4", category: "Cymatics", sub: "100·150·225·337.5 Hz — recursive triangular symmetries", voices: [L(100), C(150), C(225), R(337.5)] },
  { id: "fibonacci_quartet",name: "Fibonacci Quartet",        category: "Cymatics", sub: "100·162·262·424 Hz — φ-progression spiral patterns", voices: [L(100), C(162), C(262), R(424)] },

  // Mystic & Composers — Scriabin's Mystic Chord (Prometheus): C-F♯-B♭-E-A-D
  // Four-note voicings drawn from the six-note chord.
  { id: "scriabin_1", name: "Scriabin 1 — Mystic Core",  category: "Mystic & Composers", sub: "C–F♯–B♭–E (lower 4 of the mystic chord)", voices: [L(130.81), C(185.00), C(233.08), R(329.63)] },
  { id: "scriabin_2", name: "Scriabin 2 — Mystic Upper", category: "Mystic & Composers", sub: "F♯–B♭–E–A (upper 4 of the mystic chord)", voices: [L(185.00), C(233.08), C(329.63), R(440.00)] },
  { id: "scriabin_3", name: "Scriabin 3 — Wide Mystic",  category: "Mystic & Composers", sub: "C–B♭–A–D (spread voicing, dropped F♯/E)",  voices: [L(130.81), C(233.08), C(440.00), R(587.33)] },

  // Ligeti — Atmosphères-style chromatic micropolyphony clusters
  { id: "ligeti_1", name: "Ligeti 1 — Chromatic Cluster", category: "Mystic & Composers", sub: "C-C♯-D-D♯ tight semitone wash (Atmosphères opening)",   voices: [L(130.81), C(138.59), C(146.83), R(155.56)] },
  { id: "ligeti_2", name: "Ligeti 2 — Whole-Tone Cluster",category: "Mystic & Composers", sub: "C-D-E-F♯ whole-tone fragment, shimmering",            voices: [L(130.81), C(146.83), C(164.81), R(185.00)] },
  { id: "ligeti_3", name: "Ligeti 3 — Microtone Cluster", category: "Mystic & Composers", sub: "Quartertone cluster around A3 — 215·220·225·230 Hz",   voices: [L(215), C(220), C(225), R(230)] },

  // Solfeggio
  //
  // The Solfeggio frequencies are a modern (1970s, Puleo) numerological set
  // popularly attributed with specific therapeutic effects. Those specific
  // effects (DNA repair, detox, chakra activation, etc.) aren't clinically
  // validated — the subtitles below reflect the *traditional associations*,
  // not endorsed biological mechanisms. The meditative benefit comes from
  // sustained drone-tone listening, not the integer Hz value.
  { id: "solf_396", name: "Solfeggio 396 Hz", category: "Solfeggio", sub: "Traditionally associated with releasing fear & guilt", voices: [C(396), L(198),   R(594),    SILENT] },
  { id: "solf_417", name: "Solfeggio 417 Hz", category: "Solfeggio", sub: "Traditionally associated with breaking patterns",      voices: [C(417), L(208.5), R(625.5),  SILENT] },
  { id: "solf_528", name: "Solfeggio 528 Hz", category: "Solfeggio", sub: "Traditionally called the \"miracle\" tone",             voices: [C(528), L(264),   R(792),    SILENT] },
  { id: "solf_639", name: "Solfeggio 639 Hz", category: "Solfeggio", sub: "Traditionally associated with relational harmony",     voices: [C(639), L(319.5), R(958.5),  SILENT] },
  { id: "solf_741", name: "Solfeggio 741 Hz", category: "Solfeggio", sub: "Traditionally associated with insight",                voices: [C(741), L(370.5), R(1111.5), SILENT] },
  { id: "solf_852", name: "Solfeggio 852 Hz", category: "Solfeggio", sub: "Traditionally associated with restoring balance",      voices: [C(852), L(426),   R(1278),   SILENT] },

  // Extended Solfeggio set + Verdi 432
  { id: "solf_96",  name: "Solfeggio 96 Hz",          category: "Solfeggio", sub: "Sub-bass grounding tone",                         voices: [C(96),  L(48),    R(192),  SILENT] },
  { id: "solf_174", name: "Solfeggio 174 Hz",         category: "Solfeggio", sub: "Traditionally associated with grounding",          voices: [C(174), L(87),    R(348),  SILENT] },
  { id: "solf_285", name: "Solfeggio 285 Hz",         category: "Solfeggio", sub: "Traditionally associated with body restoration",   voices: [C(285), L(142.5), R(570),  SILENT] },
  { id: "solf_432", name: "Solfeggio 432 Hz (Verdi)", category: "Solfeggio", sub: "Alternative natural-tuning A",                     voices: [C(432), L(216),   R(864),  SILENT] },
  { id: "solf_963", name: "Solfeggio 963 Hz",         category: "Solfeggio", sub: "Traditionally associated with the crown chakra",   voices: [C(963), L(481.5), R(1926), SILENT] },

  // ─────────────────────────────────────────────────────────────────
  // Drone Artists — tributes to pioneers of long-form drone music.
  //
  // These presets carry full voice character (waveform, filter, reverb,
  // chorus, delay, sometimes LFOs + drift) so loading one captures the
  // *sound* of the artist's signature, not just their pitch material.
  // applyPreset pushes every defined field to the engine; undefined
  // fields are left alone, so users can still tweak after loading.
  //
  // These are stylistic homages, not transcriptions — meant as starting
  // points for the user to explore each artist's sound world.
  // ─────────────────────────────────────────────────────────────────

  // 1. Pauline Oliveros — Deep A Resonance.
  //    Sustained A drone with slight detune for accordion-like sympathetic
  //    beating, slow amp breathing per voice, long reverb. Tribute to
  //    Deep Listening Band's church-resonance recordings.
  {
    id: "oliveros_a", name: "Oliveros — Deep A Resonance", category: "Drone Artists",
    sub: "Pauline Oliveros · Deep Listening · slow A drone, sympathetic detune",
    voices: [
      V({ hz: 110.00,  pan: -0.4, wave: "sine", amp: 0.55, reverb: { decaySec: 8.0, mix: 0.40 },
          lfos: [{ shape: "sine", target: "amp", rateHz: 0.07, depth: 0.30 }, null, null, null] }),
      V({ hz: 220.12,  pan:  0.4, wave: "sine", amp: 0.50, reverb: { decaySec: 8.0, mix: 0.40 },
          lfos: [{ shape: "sine", target: "amp", rateHz: 0.09, depth: 0.35 }, null, null, null] }),
      V({ hz: 329.85,  pan: -0.2, wave: "sine", amp: 0.42, reverb: { decaySec: 8.0, mix: 0.40 },
          lfos: [{ shape: "sine", target: "amp", rateHz: 0.06, depth: 0.40 }, null, null, null] }),
      V({ hz: 440.00,  pan:  0.2, wave: "sine", amp: 0.38, reverb: { decaySec: 8.0, mix: 0.40 },
          lfos: [{ shape: "sine", target: "amp", rateHz: 0.08, depth: 0.35 }, null, null, null] })
    ]
  },

  // 2. Terry Riley — Rainbow Repetition.
  //    Triangle-wave organ-like timbre, just-intoned C major (root + just-3rd
  //    + 5th + octave-3rd), heavy ping-pong delay for cascading repetition
  //    à la "A Rainbow in Curved Air" / "Persian Surgery Dervishes".
  {
    id: "riley_rainbow", name: "Riley — Rainbow Repetition", category: "Drone Artists",
    sub: "Terry Riley · just-tuned C major + 1/8 ping-pong cascade",
    voices: [
      V({ hz: 130.81, pan:  0.00, wave: "triangle", amp: 0.50,
          delay: { timeSec: 0.30, feedback: 0.65, mix: 0.40, mode: "pingPong", timing: "1/8" },
          chorus: { rateHz: 0.6, depth: 0.5, width: 0.8, mix: 0.25 } }),
      V({ hz: 196.22, pan: -0.4, wave: "triangle", amp: 0.45,
          delay: { timeSec: 0.30, feedback: 0.65, mix: 0.40, mode: "pingPong", timing: "1/8" },
          chorus: { rateHz: 0.6, depth: 0.5, width: 0.8, mix: 0.25 } }),
      V({ hz: 261.63, pan:  0.4, wave: "triangle", amp: 0.45,
          delay: { timeSec: 0.30, feedback: 0.65, mix: 0.40, mode: "pingPong", timing: "1/8" },
          chorus: { rateHz: 0.6, depth: 0.5, width: 0.8, mix: 0.25 } }),
      V({ hz: 327.04, pan: -0.1, wave: "triangle", amp: 0.42,
          delay: { timeSec: 0.30, feedback: 0.65, mix: 0.40, mode: "pingPong", timing: "1/8" },
          chorus: { rateHz: 0.6, depth: 0.5, width: 0.8, mix: 0.25 } })
    ]
  },

  // 3. Éliane Radigue — Île Re-Sonante.
  //    Two pairs of voices microtonally detuned (4 cents apart on the low,
  //    0.3 Hz apart on the upper) so the air breathes at ~0.17–0.30 Hz —
  //    the slow beating that defines her ARP 2500 work.
  {
    id: "radigue_ile", name: "Radigue — Île Re-Sonante", category: "Drone Artists",
    sub: "Éliane Radigue · 4¢ + 0.3 Hz beating · static-seeming, ever-shifting",
    voices: [
      V({ hz:  73.42, pan: -0.5, wave: "sine", amp: 0.62, reverb: { decaySec: 7.0, mix: 0.30 } }),
      V({ hz:  73.59, pan:  0.5, wave: "sine", amp: 0.62, reverb: { decaySec: 7.0, mix: 0.30 } }),
      V({ hz: 220.00, pan: -0.2, wave: "sine", amp: 0.38, reverb: { decaySec: 7.0, mix: 0.30 } }),
      V({ hz: 220.30, pan:  0.2, wave: "sine", amp: 0.38, reverb: { decaySec: 7.0, mix: 0.30 } })
    ]
  },

  // 4. Stars of the Lid — Orchestral Halo.
  //    Filtered saws to evoke bowed strings, slow cutoff LFO for swelling
  //    inhale/exhale, long reverb + chorus for orchestral wash. A major
  //    triad spread across two octaves.
  {
    id: "sotl_halo", name: "Stars of the Lid — Orchestral Halo", category: "Drone Artists",
    sub: "Stars of the Lid · filtered-saw strings · A major halo, 10 s reverb",
    voices: [
      V({ hz: 110.00, pan: -0.4, wave: "sawtooth", amp: 0.50,
          filter: { type: "lowpass", cutoffHz: 800, q: 1.5 },
          reverb: { decaySec: 10.0, mix: 0.45 },
          chorus: { rateHz: 0.4, depth: 0.5, width: 1.0, mix: 0.30 },
          lfos: [null, { shape: "sine", target: "cutoff", rateHz: 0.05, depth: 0.35 }, null, null] }),
      V({ hz: 164.81, pan:  0.4, wave: "sawtooth", amp: 0.45,
          filter: { type: "lowpass", cutoffHz: 900, q: 1.5 },
          reverb: { decaySec: 10.0, mix: 0.45 },
          chorus: { rateHz: 0.4, depth: 0.5, width: 1.0, mix: 0.30 },
          lfos: [null, { shape: "sine", target: "cutoff", rateHz: 0.04, depth: 0.35 }, null, null] }),
      V({ hz: 220.00, pan: -0.2, wave: "sawtooth", amp: 0.40,
          filter: { type: "lowpass", cutoffHz: 1100, q: 1.5 },
          reverb: { decaySec: 10.0, mix: 0.45 },
          chorus: { rateHz: 0.4, depth: 0.5, width: 1.0, mix: 0.30 },
          lfos: [null, { shape: "sine", target: "cutoff", rateHz: 0.06, depth: 0.35 }, null, null] }),
      V({ hz: 277.18, pan:  0.2, wave: "sawtooth", amp: 0.35,
          filter: { type: "lowpass", cutoffHz: 1300, q: 1.5 },
          reverb: { decaySec: 10.0, mix: 0.45 },
          chorus: { rateHz: 0.4, depth: 0.5, width: 1.0, mix: 0.30 },
          lfos: [null, { shape: "sine", target: "cutoff", rateHz: 0.05, depth: 0.35 }, null, null] })
    ]
  },

  // 5. Sunn O))) — Onyx Tar.
  //    Massive low E with octave doublings, filtered to remove top end,
  //    square LFO on amplitude for slow tremolo pulse. CAUTION: lower
  //    master volume — this stack is heavy.
  {
    id: "sunn_onyx", name: "Sunn O))) — Onyx Tar", category: "Drone Artists",
    sub: "Sunn O))) · sub-bass E drone · square-LFO tremolo · drop master volume",
    voices: [
      V({ hz:  41.20, pan: -0.5, wave: "sawtooth", amp: 0.75,
          filter: { type: "lowpass", cutoffHz: 350, q: 2.0 },
          reverb: { decaySec: 9.0, mix: 0.45 },
          lfos: [{ shape: "square", target: "amp", rateHz: 0.7, depth: 0.30 }, null, null, null] }),
      V({ hz:  41.55, pan:  0.5, wave: "square",   amp: 0.70,
          filter: { type: "lowpass", cutoffHz: 400, q: 1.8 },
          reverb: { decaySec: 9.0, mix: 0.45 },
          lfos: [{ shape: "square", target: "amp", rateHz: 0.7, depth: 0.30 }, null, null, null] }),
      V({ hz:  82.40, pan:  0.0, wave: "sawtooth", amp: 0.55,
          filter: { type: "lowpass", cutoffHz: 500, q: 1.5 },
          reverb: { decaySec: 9.0, mix: 0.45 } }),
      V({ hz: 123.47, pan:  0.1, wave: "sawtooth", amp: 0.40,
          filter: { type: "lowpass", cutoffHz: 700, q: 1.5 },
          reverb: { decaySec: 9.0, mix: 0.45 } })
    ]
  },

  // 6. William Basinski — Disintegration.
  //    Voice 1 acts as a slowly-decaying "tape loop": amp LFO fades it in
  //    and out (~12 s cycle) and cutoff LFO progressively darkens it.
  //    Other voices support in C major. 1/4 delay for repeated phrase.
  {
    id: "basinski_disint", name: "Basinski — Disintegration", category: "Drone Artists",
    sub: "Basinski · tape-loop voice fading + filter-decay · C major support",
    voices: [
      V({ hz: 261.63, pan:  0.0, wave: "triangle", amp: 0.55,
          filter: { type: "lowpass", cutoffHz: 1500, q: 1.0 },
          delay: { timeSec: 0.50, feedback: 0.65, mix: 0.40, mode: "stereo", timing: "1/4" },
          reverb: { decaySec: 7.0, mix: 0.40 },
          lfos: [
            { shape: "sine", target: "amp",    rateHz: 0.08, depth: 0.45 },
            { shape: "sine", target: "cutoff", rateHz: 0.03, depth: 0.55 },
            null, null
          ] }),
      V({ hz: 130.81, pan:  0.0, wave: "sine", amp: 0.45, reverb: { decaySec: 7.0, mix: 0.40 } }),
      V({ hz: 392.00, pan: -0.3, wave: "sine", amp: 0.35, reverb: { decaySec: 7.0, mix: 0.40 } }),
      V({ hz: 523.25, pan:  0.3, wave: "sine", amp: 0.32, reverb: { decaySec: 7.0, mix: 0.40 } })
    ]
  },

  // 7. Phill Niblock — Tight Cluster.
  //    Four sawtooth voices clustered within ~20 cents around A3 — wide
  //    stereo pan so the close-interval beating moves around the room.
  //    Short reverb because the cluster IS the room.
  {
    id: "niblock_cluster", name: "Niblock — Tight Cluster", category: "Drone Artists",
    sub: "Phill Niblock · 4-voice microtonal cluster · beating as harmony",
    voices: [
      V({ hz: 220.00, pan: -0.8, wave: "sawtooth", amp: 0.45,
          filter: { type: "lowpass", cutoffHz: 2000, q: 0.7 },
          reverb: { decaySec: 3.0, mix: 0.20 } }),
      V({ hz: 222.55, pan: -0.3, wave: "sawtooth", amp: 0.45,
          filter: { type: "lowpass", cutoffHz: 2000, q: 0.7 },
          reverb: { decaySec: 3.0, mix: 0.20 } }),
      V({ hz: 218.45, pan:  0.3, wave: "sawtooth", amp: 0.45,
          filter: { type: "lowpass", cutoffHz: 2000, q: 0.7 },
          reverb: { decaySec: 3.0, mix: 0.20 } }),
      V({ hz: 221.25, pan:  0.8, wave: "sawtooth", amp: 0.45,
          filter: { type: "lowpass", cutoffHz: 2000, q: 0.7 },
          reverb: { decaySec: 3.0, mix: 0.20 } })
    ]
  },

  // 8. Charlemagne Palestine — Strumming Overtones.
  //    Tribute to "Strumming Music" — heavily-chorused triangle + saw layers
  //    with just-tuned D + F# (5/4) major-third pair, simulating the over-
  //    tone richness of a strummed Bösendorfer.
  {
    id: "palestine_strum", name: "Palestine — Strumming Overtones", category: "Drone Artists",
    sub: "Charlemagne Palestine · just D + 5/4 F# · piano-sustain chorus wash",
    voices: [
      V({ hz:  73.42, pan: -0.2, wave: "triangle", amp: 0.60,
          chorus: { rateHz: 0.5, depth: 0.7, width: 1.0, mix: 0.40 },
          reverb: { decaySec: 5.0, mix: 0.35 } }),
      V({ hz:  91.78, pan:  0.2, wave: "triangle", amp: 0.50,
          chorus: { rateHz: 0.5, depth: 0.7, width: 1.0, mix: 0.40 },
          reverb: { decaySec: 5.0, mix: 0.35 } }),
      V({ hz: 220.00, pan: -0.4, wave: "sawtooth", amp: 0.38,
          filter: { type: "lowpass", cutoffHz: 2500, q: 0.7 },
          chorus: { rateHz: 0.5, depth: 0.7, width: 1.0, mix: 0.40 },
          reverb: { decaySec: 5.0, mix: 0.35 } }),
      V({ hz: 293.66, pan:  0.4, wave: "sawtooth", amp: 0.38,
          filter: { type: "lowpass", cutoffHz: 2800, q: 0.7 },
          chorus: { rateHz: 0.5, depth: 0.7, width: 1.0, mix: 0.40 },
          reverb: { decaySec: 5.0, mix: 0.35 } })
    ]
  },

  // 9. Yoshi Wada — Bagpipe Drone.
  //    Just-intoned A drone with perfect fifth (3/2) + just second (9/8),
  //    sawtooth + LP filter + heavy chorus to simulate the multi-reed
  //    interaction of bagpipes. Subtle 5 Hz pitch LFO for reed wobble.
  {
    id: "wada_bagpipe", name: "Wada — Bagpipe Drone", category: "Drone Artists",
    sub: "Yoshi Wada · just A + 3/2 + 9/8 · reed wobble + multi-reed chorus",
    voices: [
      V({ hz: 110.00, pan:  0.0, wave: "sawtooth", amp: 0.65,
          filter: { type: "lowpass", cutoffHz: 1800, q: 1.0 },
          chorus: { rateHz: 0.7, depth: 0.6, width: 0.7, mix: 0.40 },
          reverb: { decaySec: 4.0, mix: 0.30 },
          lfos: [null, null, null, { shape: "sine", target: "pitch", rateHz: 5.0, depth: 0.02 }] }),
      V({ hz: 220.00, pan: -0.4, wave: "sawtooth", amp: 0.45,
          filter: { type: "lowpass", cutoffHz: 2200, q: 1.0 },
          chorus: { rateHz: 0.7, depth: 0.6, width: 0.7, mix: 0.40 },
          reverb: { decaySec: 4.0, mix: 0.30 } }),
      V({ hz: 165.00, pan:  0.4, wave: "sawtooth", amp: 0.42,
          filter: { type: "lowpass", cutoffHz: 2000, q: 1.0 },
          chorus: { rateHz: 0.7, depth: 0.6, width: 0.7, mix: 0.40 },
          reverb: { decaySec: 4.0, mix: 0.30 } }),
      V({ hz: 247.50, pan: -0.2, wave: "sawtooth", amp: 0.30,
          filter: { type: "lowpass", cutoffHz: 2500, q: 1.0 },
          chorus: { rateHz: 0.7, depth: 0.6, width: 0.7, mix: 0.40 },
          reverb: { decaySec: 4.0, mix: 0.30 } })
    ]
  },

  // 10. Harold Budd — Pearl Pad.
  //     Soft sine + triangle, C major7, slow amp LFO breathing, very long
  //     reverb. Mirror of the gentle suspended pads of "The Pearl" (with
  //     Eno) and "The Pavilion of Dreams".
  {
    id: "budd_pearl", name: "Budd — Pearl Pad", category: "Drone Artists",
    sub: "Harold Budd · soft Cmaj7 pad · breathing amp LFO · 9 s reverb halo",
    voices: [
      V({ hz: 130.81, pan: -0.3, wave: "sine", amp: 0.50,
          reverb: { decaySec: 9.0, mix: 0.50 },
          chorus: { rateHz: 0.3, depth: 0.4, width: 0.6, mix: 0.25 },
          lfos: [{ shape: "sine", target: "amp", rateHz: 0.04, depth: 0.40 }, null, null, null] }),
      V({ hz: 196.00, pan:  0.3, wave: "sine", amp: 0.45,
          reverb: { decaySec: 9.0, mix: 0.50 },
          chorus: { rateHz: 0.3, depth: 0.4, width: 0.6, mix: 0.25 },
          lfos: [{ shape: "sine", target: "amp", rateHz: 0.05, depth: 0.40 }, null, null, null] }),
      V({ hz: 261.63, pan: -0.2, wave: "triangle", amp: 0.38,
          reverb: { decaySec: 9.0, mix: 0.50 },
          chorus: { rateHz: 0.3, depth: 0.4, width: 0.6, mix: 0.25 },
          lfos: [{ shape: "sine", target: "amp", rateHz: 0.03, depth: 0.40 }, null, null, null] }),
      V({ hz: 329.63, pan:  0.2, wave: "triangle", amp: 0.35,
          reverb: { decaySec: 9.0, mix: 0.50 },
          chorus: { rateHz: 0.3, depth: 0.4, width: 0.6, mix: 0.25 },
          lfos: [{ shape: "sine", target: "amp", rateHz: 0.045, depth: 0.40 }, null, null, null] })
    ]
  },

  // 11. Alice Coltrane — Spiritual Organ.
  //     Bb minor 7 organ stack (Wurlitzer/Hammond-ish saws with LP), pan-LFO
  //     for Leslie rotation, fast chorus for Leslie tremolo, medium reverb.
  {
    id: "acoltrane_organ", name: "Coltrane — Spiritual Organ", category: "Drone Artists",
    sub: "Alice Coltrane · Bbm7 organ · Leslie pan rotation + tremolo",
    voices: [
      V({ hz:  58.27, pan:  0.0, wave: "sawtooth", amp: 0.60,
          filter: { type: "lowpass", cutoffHz: 1500, q: 1.0 },
          chorus: { rateHz: 6.0, depth: 0.7, width: 1.0, mix: 0.50 },
          reverb: { decaySec: 4.0, mix: 0.40 },
          lfos: [null, null, { shape: "sine", target: "pan", rateHz: 0.8, depth: 0.40 }, null] }),
      V({ hz: 116.54, pan: -0.4, wave: "sawtooth", amp: 0.45,
          filter: { type: "lowpass", cutoffHz: 2000, q: 1.0 },
          chorus: { rateHz: 6.0, depth: 0.7, width: 1.0, mix: 0.50 },
          reverb: { decaySec: 4.0, mix: 0.40 },
          lfos: [null, null, { shape: "sine", target: "pan", rateHz: 0.8, depth: 0.40 }, null] }),
      V({ hz: 174.61, pan:  0.4, wave: "sawtooth", amp: 0.40,
          filter: { type: "lowpass", cutoffHz: 2200, q: 1.0 },
          chorus: { rateHz: 6.0, depth: 0.7, width: 1.0, mix: 0.50 },
          reverb: { decaySec: 4.0, mix: 0.40 },
          lfos: [null, null, { shape: "sine", target: "pan", rateHz: 0.8, depth: 0.40 }, null] }),
      V({ hz: 207.65, pan:  0.0, wave: "triangle", amp: 0.36,
          chorus: { rateHz: 6.0, depth: 0.7, width: 1.0, mix: 0.50 },
          reverb: { decaySec: 4.0, mix: 0.40 } })
    ]
  },

  // 12. Earth — Tar Pit (Earth 2 style).
  //     Slower than Sunn O))) — very low B + perfect fourth, heavy reverb,
  //     drift glacial-down so the whole drone descends across the session.
  {
    id: "earth_tarpit", name: "Earth — Tar Pit", category: "Drone Artists",
    sub: "Earth (Carlson) · Earth-2 doom · low B + 4th · 10 s reverb",
    voices: [
      V({ hz:  30.87, pan: -0.3, wave: "sawtooth", amp: 0.70,
          filter: { type: "lowpass", cutoffHz: 250, q: 2.0 },
          reverb: { decaySec: 10.0, mix: 0.50 },
          drift: { pitchMode: "glacial", pitchAmount: 0.3, panMode: "static", panAmount: 0, pitchPhase: 0, panPhase: 0 } }),
      V({ hz:  41.20, pan:  0.3, wave: "sawtooth", amp: 0.65,
          filter: { type: "lowpass", cutoffHz: 280, q: 1.8 },
          reverb: { decaySec: 10.0, mix: 0.50 },
          drift: { pitchMode: "glacial", pitchAmount: 0.3, panMode: "static", panAmount: 0, pitchPhase: 0.25, panPhase: 0 } }),
      V({ hz:  61.74, pan:  0.0, wave: "square",   amp: 0.50,
          filter: { type: "lowpass", cutoffHz: 400, q: 1.5 },
          reverb: { decaySec: 10.0, mix: 0.50 } }),
      V({ hz:  92.50, pan:  0.0, wave: "sine",     amp: 0.35,
          reverb: { decaySec: 10.0, mix: 0.50 } })
    ]
  },

  // 13. Nurse With Wound — Avant Tableau.
  //     Stranger, asymmetric — mixed waveforms across voices, wide pan,
  //     S&H LFO on osc-2 cutoff, FM-style cross-modulation (osc 4 → osc 1)
  //     via a small modulation index, ping-pong 1/4-triplet delay.
  {
    id: "nww_tableau", name: "Nurse With Wound — Avant Tableau", category: "Drone Artists",
    sub: "Nurse With Wound · asymmetric collage · cross-osc FM + ping-pong 1/4T",
    voices: [
      V({ hz:  87.31, pan: -0.8, wave: "sawtooth", amp: 0.50,
          filter: { type: "lowpass", cutoffHz: 900, q: 1.0 },
          fm: { sourceIndex: 3, index: 60 },
          delay: { timeSec: 0.40, feedback: 0.55, mix: 0.30, mode: "pingPong", timing: "1/4t" },
          reverb: { decaySec: 6.0, mix: 0.35 } }),
      V({ hz: 233.08, pan:  0.8, wave: "square",   amp: 0.35,
          filter: { type: "highpass", cutoffHz: 400, q: 2.5 },
          reverb: { decaySec: 6.0, mix: 0.35 },
          lfos: [null, { shape: "sh", target: "cutoff", rateHz: 0.15, depth: 0.55 }, null, null] }),
      V({ hz: 311.13, pan: -0.3, wave: "sine",     amp: 0.30,
          reverb: { decaySec: 6.0, mix: 0.35 } }),
      V({ hz: 415.30, pan:  0.3, wave: "triangle", amp: 0.28,
          reverb: { decaySec: 6.0, mix: 0.35 } })
    ]
  },

  // 14. Keiji Haino — Spectral Shimmer.
  //     Low D drone + high HP-filtered shimmer pair an octave + minor-3rd
  //     apart, subtle pitch LFO on the shimmer voices, heavy chorus,
  //     long reverb. Suggests Haino's filtered-feedback meditative pieces.
  {
    id: "haino_shimmer", name: "Haino — Spectral Shimmer", category: "Drone Artists",
    sub: "Keiji Haino · D drone + HP shimmer · wobble + chorus halo",
    voices: [
      V({ hz:  73.42, pan:  0.0, wave: "sawtooth", amp: 0.55,
          filter: { type: "lowpass", cutoffHz: 800, q: 2.0 },
          chorus: { rateHz: 1.5, depth: 0.7, width: 1.0, mix: 0.50 },
          reverb: { decaySec: 5.0, mix: 0.40 } }),
      V({ hz: 880.00, pan: -0.6, wave: "sawtooth", amp: 0.22,
          filter: { type: "highpass", cutoffHz: 600, q: 3.0 },
          chorus: { rateHz: 1.5, depth: 0.7, width: 1.0, mix: 0.50 },
          reverb: { decaySec: 5.0, mix: 0.40 },
          lfos: [null, null, null, { shape: "sine", target: "pitch", rateHz: 0.8, depth: 0.05 }] }),
      V({ hz: 1108.73, pan: 0.6, wave: "sawtooth", amp: 0.18,
          filter: { type: "highpass", cutoffHz: 700, q: 3.0 },
          chorus: { rateHz: 1.5, depth: 0.7, width: 1.0, mix: 0.50 },
          reverb: { decaySec: 5.0, mix: 0.40 },
          lfos: [null, null, null, { shape: "sine", target: "pitch", rateHz: 0.7, depth: 0.05 }] }),
      V({ hz: 220.00, pan:  0.0, wave: "square",   amp: 0.25,
          filter: { type: "lowpass", cutoffHz: 1500, q: 1.0 },
          reverb: { decaySec: 5.0, mix: 0.40 } })
    ]
  }
];

// ────────────────────────────────────────────────────────────
// Meditation journeys — scripted multi-stage sessions.
// ────────────────────────────────────────────────────────────
//
// Each journey is a sequence of stages; when started, the journey auto-
// advances through the stages on a timer, loading the stage's preset and
// applying its drift scene as it goes. The transport's session duration
// is automatically set to the journey total so the existing fade-out
// behavior kicks in at the end.
//
// A stage references presets and drift scenes by id — both must exist in
// PRESETS and DRIFT_SCENES (defined in music.js / main.js) respectively.

export const JOURNEYS = [
  {
    id: "sundown",
    name: "Sundown",
    description: "Bright clarity slowly descending into deep rest. Good for end of day.",
    stages: [
      { durationSec: 5 * 60,  presetId: "solf_528",     driftSceneId: "glacial",    hint: "Pure 528 Hz · gentle wander" },
      { durationSec: 10 * 60, presetId: "scriabin_2",   driftSceneId: "breathing",  hint: "Mystic chord · breathing" },
      { durationSec: 5 * 60,  presetId: "sable",        driftSceneId: "descend",    hint: "φ-tuned descent" }
    ]
  },
  {
    id: "awakening",
    name: "Awakening",
    description: "Deep root rising into bright resonance. Good for morning focus.",
    stages: [
      { durationSec: 5 * 60,  presetId: "om",                  driftSceneId: "off",       hint: "OM 136.1 Hz · still" },
      { durationSec: 5 * 60,  presetId: "harmonic_series",     driftSceneId: "ascend",    hint: "Harmonic series · ascending" },
      { durationSec: 5 * 60,  presetId: "just_major",          driftSceneId: "aurora",    hint: "Just major triad · aurora" }
    ]
  },
  {
    id: "floating",
    name: "Floating",
    description: "Sustained ambient texture for long sessions or sleep onset.",
    stages: [
      { durationSec: 10 * 60, presetId: "phi_field",     driftSceneId: "aurora",     hint: "Phi field · aurora" },
      { durationSec: 10 * 60, presetId: "schumann_x",    driftSceneId: "tidal",      hint: "Schumann layers · tidal" },
      { durationSec: 10 * 60, presetId: "ligeti_2",      driftSceneId: "pendulum",   hint: "Whole-tone cluster · pendulum" }
    ]
  },
  {
    id: "centering",
    name: "Centering",
    description: "Short focus session — 10 minutes total, ideal for a quick reset.",
    stages: [
      { durationSec: 3 * 60,  presetId: "hypogeum",         driftSceneId: "off",       hint: "Hypogeum 111 Hz · still" },
      { durationSec: 4 * 60,  presetId: "phi_aug",          driftSceneId: "glacial",   hint: "Phi-augmented · wander" },
      { durationSec: 3 * 60,  presetId: "earth",            driftSceneId: "downUp",    hint: "Schumann fundamental · return" }
    ]
  },
  {
    id: "spiralDescent",
    name: "Spiral Descent",
    description: "Outer voices spiral around a central drone, slowly descending. 25 min.",
    stages: [
      { durationSec: 5 * 60,  presetId: "fifths_stack",     driftSceneId: "spiral",     hint: "Perfect fifths · spiral" },
      { durationSec: 10 * 60, presetId: "fibonacci_quartet",driftSceneId: "convergence",hint: "Fibonacci · converging" },
      { durationSec: 10 * 60, presetId: "octave_stack",     driftSceneId: "descend",    hint: "Octave stack · descending" }
    ]
  },
  {
    id: "bodyScan",
    name: "Body Scan",
    description: "Progressive solfeggio sweep — root chakra up through the crown. 20 min.",
    stages: [
      { durationSec: 4 * 60, presetId: "solf_174", driftSceneId: "off",       hint: "174 Hz · feet, grounding" },
      { durationSec: 4 * 60, presetId: "solf_396", driftSceneId: "glacial",   hint: "396 Hz · root" },
      { durationSec: 4 * 60, presetId: "solf_528", driftSceneId: "breathing", hint: "528 Hz · heart" },
      { durationSec: 4 * 60, presetId: "solf_741", driftSceneId: "aurora",    hint: "741 Hz · throat / intuition" },
      { durationSec: 4 * 60, presetId: "solf_963", driftSceneId: "tidal",     hint: "963 Hz · crown" }
    ]
  },
  {
    id: "cathedral",
    name: "Cathedral",
    description: "Sacred geometry — phi, just intonation, hypogeum resonance. 20 min.",
    stages: [
      { durationSec: 5 * 60,  presetId: "hypogeum",     driftSceneId: "aurora",   hint: "Hypogeum 111 Hz · aurora" },
      { durationSec: 10 * 60, presetId: "just_major",   driftSceneId: "pendulum", hint: "Just major triad · pendulum" },
      { durationSec: 5 * 60,  presetId: "phi_field",    driftSceneId: "glacial",  hint: "Phi field · settle" }
    ]
  },
  {
    id: "mountainClimb",
    name: "Mountain Climb",
    description: "Slowly ascending energy from deep root to crown. 30 min.",
    stages: [
      { durationSec: 10 * 60, presetId: "om",       driftSceneId: "off",      hint: "OM 136.1 Hz · steady" },
      { durationSec: 10 * 60, presetId: "solf_528", driftSceneId: "ascend",   hint: "528 Hz · ascending" },
      { durationSec: 10 * 60, presetId: "solf_963", driftSceneId: "spiral",   hint: "963 Hz · crown spiral" }
    ]
  },
  {
    id: "vespers",
    name: "Vespers",
    description: "Evening contemplation — mystic chords descending into rest. 20 min.",
    stages: [
      { durationSec: 5 * 60,  presetId: "solf_432",   driftSceneId: "downUp",   hint: "Verdi 432 · breath" },
      { durationSec: 10 * 60, presetId: "scriabin_1", driftSceneId: "pendulum", hint: "Scriabin mystic · pendulum" },
      { durationSec: 5 * 60,  presetId: "sable",      driftSceneId: "descend",  hint: "Sable's chord · settling" }
    ]
  },
  {
    id: "crystalCave",
    name: "Crystal Cave",
    description: "Bright high-frequency textures with stereo motion. 25 min.",
    stages: [
      { durationSec: 10 * 60, presetId: "just_major",        driftSceneId: "aurora",   hint: "Just major · aurora" },
      { durationSec: 10 * 60, presetId: "fibonacci_quartet", driftSceneId: "crossing", hint: "Fibonacci · crossing paths" },
      { durationSec: 5 * 60,  presetId: "phi_aug",           driftSceneId: "glacial",  hint: "Phi-augmented · resolve" }
    ]
  },
  {
    id: "phiSpiral",
    name: "Phi Spiral",
    description: "Golden-ratio frequencies, slowly turning. 30 min.",
    stages: [
      { durationSec: 10 * 60, presetId: "phi_field",  driftSceneId: "spiral",    hint: "Phi field · spiral" },
      { durationSec: 10 * 60, presetId: "phi_aug",    driftSceneId: "breathing", hint: "Phi-augmented · breathing" },
      { durationSec: 10 * 60, presetId: "sable",      driftSceneId: "downUp",    hint: "Sable · breath" }
    ]
  },
  {
    id: "quartz",
    name: "Quartz",
    description: "Clean integer-ratio harmonics — the bones of pitched sound. 15 min.",
    stages: [
      { durationSec: 5 * 60, presetId: "harmonic_series",  driftSceneId: "off",          hint: "1:2:3:4 · still" },
      { durationSec: 5 * 60, presetId: "octave_stack",     driftSceneId: "ascend",       hint: "Octave stack · ascending" },
      { durationSec: 5 * 60, presetId: "fibonacci_quartet",driftSceneId: "convergence",  hint: "Fibonacci · converging" }
    ]
  },
  {
    id: "lullaby",
    name: "Lullaby",
    description: "Short sleep-onset session — theta + delta carriers. 10 min.",
    stages: [
      { durationSec: 5 * 60, presetId: "theta_tri", driftSceneId: "breathing", hint: "Theta triad · breathing" },
      { durationSec: 5 * 60, presetId: "delta_4",   driftSceneId: "downUp",    hint: "Delta 4 Hz · into sleep" }
    ]
  },
  {
    id: "tibetanBowl",
    name: "Tibetan Bowl",
    description: "Classic drone meditation — three deep tones, glacial throughout. 15 min.",
    stages: [
      { durationSec: 5 * 60, presetId: "om",       driftSceneId: "glacial", hint: "OM 136.1 Hz · settle" },
      { durationSec: 5 * 60, presetId: "hypogeum", driftSceneId: "glacial", hint: "Hypogeum 111 Hz · deepen" },
      { durationSec: 5 * 60, presetId: "earth",    driftSceneId: "glacial", hint: "Earth Schumann · resolve" }
    ]
  },
  {
    id: "stormFront",
    name: "Storm Front",
    description: "Tension building then resolving — Ligeti clusters into convergence. 12 min.",
    stages: [
      { durationSec: 4 * 60, presetId: "ligeti_1", driftSceneId: "glacial",     hint: "Chromatic cluster · wander" },
      { durationSec: 4 * 60, presetId: "ligeti_3", driftSceneId: "crossing",    hint: "Quartertone cluster · crossing" },
      { durationSec: 4 * 60, presetId: "om",       driftSceneId: "convergence", hint: "OM · convergence resolve" }
    ]
  },

  // ─────────────────────────────────────────────────────────────────
  // Drone-music lineage journeys — guided tours through the new
  // Drone Artists presets. Each one traces a thematic arc through
  // 3 artists' sound worlds.
  // ─────────────────────────────────────────────────────────────────
  {
    id: "deepListeningLineage",
    name: "Deep Listening Lineage",
    description: "45 min through Oliveros → Radigue → Stars of the Lid — the contemplative thread of 20th-century drone.",
    stages: [
      { durationSec: 15 * 60, presetId: "oliveros_a",  driftSceneId: "glacial",   hint: "Oliveros · breathing A drone" },
      { durationSec: 15 * 60, presetId: "radigue_ile", driftSceneId: "breathing", hint: "Radigue · microtonal beating" },
      { durationSec: 15 * 60, presetId: "sotl_halo",   driftSceneId: "aurora",    hint: "Stars of the Lid · orchestral halo" }
    ]
  },
  {
    id: "heavyResonance",
    name: "Heavy Resonance",
    description: "30 min of low-end immersion — Sunn O))) → Earth → Niblock. Lower master volume before starting.",
    stages: [
      { durationSec: 10 * 60, presetId: "sunn_onyx",       driftSceneId: "off",      hint: "Sunn O))) · sub-bass tremolo" },
      { durationSec: 10 * 60, presetId: "earth_tarpit",    driftSceneId: "descend",  hint: "Earth · glacial descent" },
      { durationSec: 10 * 60, presetId: "niblock_cluster", driftSceneId: "crossing", hint: "Niblock · beating cluster" }
    ]
  },
  {
    id: "minimalistArc",
    name: "Minimalist Arc",
    description: "25 min from Riley's repetition through Budd's pearls to Palestine's strummed overtones.",
    stages: [
      { durationSec:  8 * 60, presetId: "riley_rainbow",     driftSceneId: "off",      hint: "Riley · rainbow cascade" },
      { durationSec: 10 * 60, presetId: "budd_pearl",        driftSceneId: "breathing",hint: "Budd · breathing pad" },
      { durationSec:  7 * 60, presetId: "palestine_strum",   driftSceneId: "aurora",   hint: "Palestine · overtone wash" }
    ]
  },
  {
    id: "spiritualPath",
    name: "Spiritual Path",
    description: "35 min · Alice Coltrane's Leslie organ → Wada's bagpipe just-intonation → Haino's shimmer halo.",
    stages: [
      { durationSec: 12 * 60, presetId: "acoltrane_organ", driftSceneId: "aurora",   hint: "Coltrane · Leslie rotation" },
      { durationSec: 13 * 60, presetId: "wada_bagpipe",    driftSceneId: "off",      hint: "Wada · reed drone" },
      { durationSec: 10 * 60, presetId: "haino_shimmer",   driftSceneId: "ascend",   hint: "Haino · spectral shimmer" }
    ]
  }
];

export function journeyTotalSeconds(journey) {
  return journey.stages.reduce((s, st) => s + st.durationSec, 0);
}

// ────────────────────────────────────────────────────────────
// Misc constants.
// ────────────────────────────────────────────────────────────
export const FREQ_MIN = 20;
export const FREQ_MAX = 2000;

/** Map a frequency to a hue 0..1 for visualizations (low = warm, high = cool). */
export function frequencyHue(hz) {
  const logF = Math.log2(Math.max(hz, FREQ_MIN));
  const lo = Math.log2(FREQ_MIN), hi = Math.log2(FREQ_MAX);
  const t = (logF - lo) / (hi - lo);
  return 0.05 + 0.6 * t;
}
