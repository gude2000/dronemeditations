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
  { id: "equal12",        name: "12-TET",      snap: (c) => snapEqual(c, 100) },
  { id: "equal24",        name: "24-TET",      snap: (c) => snapEqual(c, 50) },
  { id: "equal72",        name: "72-TET",      snap: (c) => snapEqual(c, 1200 / 72) },
  { id: "wholeTone",      name: "Whole Tone",  snap: (c) => snapEqual(c, 200) },
  { id: "justIntonation", name: "Just",        snap: (c) => snapTable(c, JUST_CENTS, 1200) },
  { id: "pythagorean",    name: "Pythagorean", snap: (c) => snapTable(c, PYTHAG_CENTS, 1200) },
  { id: "phi",            name: "Phi (φ)",     snap: (c) => snapEqual(c, PHI_OCTAVE_CENTS / 13) }
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

export const PRESET_CATEGORIES = [
  "Binaural — 2 tone",
  "Binaural — 3 tone",
  "Binaural — 4 tone",
  "Natural Resonance",
  "Solfeggio"
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
  { id: "om",     name: "OM 136.1 Hz",                    category: "Natural Resonance", sub: "Tuned to Earth's year",   voices: [C(136.1), C(272.2), L(204.15), R(204.15)] },
  { id: "moon",   name: "Moon 210.42 Hz",                 category: "Natural Resonance", sub: "Cosmic-octave moon orbit",voices: [C(210.42), L(105.21), R(315.63), C(420.84)] },
  { id: "sun",    name: "Sun 126.22 Hz",                  category: "Natural Resonance", sub: "Cosmic-octave solar",     voices: [C(126.22), L(63.11), R(189.33), C(252.44)] },

  // Solfeggio
  { id: "solf_396", name: "Solfeggio 396 Hz", category: "Solfeggio", sub: "Liberating guilt",     voices: [C(396), L(198),   R(594),    SILENT] },
  { id: "solf_417", name: "Solfeggio 417 Hz", category: "Solfeggio", sub: "Facilitating change",  voices: [C(417), L(208.5), R(625.5),  SILENT] },
  { id: "solf_528", name: "Solfeggio 528 Hz", category: "Solfeggio", sub: "Repair / DNA",         voices: [C(528), L(264),   R(792),    SILENT] },
  { id: "solf_639", name: "Solfeggio 639 Hz", category: "Solfeggio", sub: "Connection",           voices: [C(639), L(319.5), R(958.5),  SILENT] },
  { id: "solf_741", name: "Solfeggio 741 Hz", category: "Solfeggio", sub: "Awakening intuition",  voices: [C(741), L(370.5), R(1111.5), SILENT] },
  { id: "solf_852", name: "Solfeggio 852 Hz", category: "Solfeggio", sub: "Returning to order",   voices: [C(852), L(426),   R(1278),   SILENT] }
];

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
