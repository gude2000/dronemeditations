// Chladni eigenmode calibration — empirical, antisymmetric basis.
//
// Calibration table merges visual identification from two reference videos:
//   • a smaller free-edge plate (86–650 Hz, simple low-mode patterns)
//   • brusspup's larger center-driven plate (345–6051 Hz, dense modes)
//
// All entries are antisymmetric (m, n) pairs with m < n. The antisymmetric
// Chladni formula
//   field(x, y) = ½·[cos(mπx)cos(nπy) − cos(nπx)cos(mπy)]
// reproduces the 4-fold symmetric saltire/bowtie/diamond patterns that real
// plates actually show. Diagonal (m, m) modes were discarded — they fit the
// f ≈ K·(m²+n²) formula nicely but render as plain m×m grids, which is not
// what either reference video shows at the corresponding frequencies.
//
// At any input frequency we look up the two adjacent table points and
// crossfade their (m, n) modes, so a slow pitch sweep morphs smoothly
// between the physical patterns the real plates show at those frequencies.

const CALIBRATION = [
  // Bass region (small plate, simple low-mode patterns)
  { freq:   86, m: 1, n:  2 },  // simple cross / closed loop
  { freq:  230, m: 2, n:  3 },  // 4 corner regions + center
  { freq:  285, m: 1, n:  6 },  // horizontal "DNA" stripe mode
  { freq:  345, m: 2, n:  4 },  // 4-petal bowtie (brusspup)
  { freq:  460, m: 3, n:  4 },  // X / saltire with center
  { freq:  575, m: 3, n:  5 },  // 4 large lobes
  { freq:  650, m: 3, n:  5 },  // 4 lobes, slightly more elaborate

  // Mid–high region (brusspup plate, dense saltires)
  { freq: 1033, m: 4, n:  5 },  // central diamond + 8 surrounding circles
  { freq: 1820, m: 6, n:  7 },  // complex interlocking curves
  { freq: 2041, m: 7, n:  8 },
  { freq: 3240, m: 9, n: 10 },
  { freq: 3835, m: 9, n: 11 },
  { freq: 3975, m: 9, n: 12 },
  { freq: 4049, m: 10, n: 11 },
  { freq: 4129, m: 1,  n: 15 },  // pure horizontal stripes (driver-offset)
  { freq: 4173, m: 3,  n: 15 },
  { freq: 4221, m: 7,  n: 13 },
  { freq: 4280, m: 2,  n: 15 },
  { freq: 4444, m: 4,  n: 15 },
  { freq: 4671, m: 5,  n: 15 },
  { freq: 4840, m: 9,  n: 13 },
  { freq: 5201, m: 10, n: 13 },
  { freq: 5284, m: 11, n: 13 },
  { freq: 5907, m: 12, n: 13 },
  { freq: 6051, m: 12, n: 14 },  // re-ID'd from (13,13); densely packed
];

// Local plate constant for extrapolation below the lowest measured point.
// (1,2) at 86 Hz gives K = 86/5 = 17.2.
const K_PLATE_BASS = 86 / 5;

export const K_PLATE = K_PLATE_BASS;  // exported for diagnostics/tests

/**
 * Pick two (m, n) eigenmodes to render at the given frequency, with
 * crossfade weights that sum to 1. Uses the empirical calibration table for
 * 86 Hz ≤ f ≤ 6051 Hz; extrapolates to (1, ⌈f/K⌉) for sub-bass below 86 Hz;
 * clamps to the top entry above 6051 Hz.
 */
export function modePairForFreq(freq) {
  const f = Math.max(0, freq);

  // Sub-bass: below the lowest measured point — extrapolate as a (1, n)
  // mode where n grows with frequency. Picks small-mode patterns down to
  // the fundamental (1, 1).
  if (f <= CALIBRATION[0].freq) {
    const target = f / K_PLATE_BASS;
    // Solve 1² + n² ≈ target → n ≈ sqrt(target - 1).
    const nFloat = Math.sqrt(Math.max(0, target - 1));
    const nLo = Math.max(1, Math.floor(nFloat));
    const nHi = Math.max(nLo + 1, nLo + 1);
    const a = { m: 1, n: nLo };
    const b = { m: 1, n: nHi };
    const t = Math.max(0, Math.min(1, nFloat - nLo));
    return [
      { m: a.m, n: a.n, weight: 1 - t },
      { m: b.m, n: b.n, weight: t }
    ];
  }

  // Above the highest measured — pin to the top mode.
  const lastIdx = CALIBRATION.length - 1;
  if (f >= CALIBRATION[lastIdx].freq) {
    const last = CALIBRATION[lastIdx];
    return [
      { m: last.m, n: last.n, weight: 1 },
      { m: last.m, n: last.n, weight: 0 }
    ];
  }

  // Between two measured points: crossfade linearly in frequency.
  let lo = 0, hi = lastIdx;
  while (lo < hi - 1) {
    const mid = (lo + hi) >> 1;
    if (CALIBRATION[mid].freq <= f) lo = mid;
    else hi = mid;
  }
  const a = CALIBRATION[lo];
  const b = CALIBRATION[hi];
  const t = (f - a.freq) / (b.freq - a.freq);
  return [
    { m: a.m, n: a.n, weight: 1 - t },
    { m: b.m, n: b.n, weight: t }
  ];
}

/**
 * Evaluate the Chladni nodal field at (x, y) ∈ [0,1]² for a list of weighted
 * (m, n) modes. Used by the sand particle simulation (CPU) and mirrored in
 * the WebGL fragment shader (GPU).
 *
 * Every entry in the calibration table satisfies m < n, so this is always
 * the antisymmetric Chladni formula — the basis function that produces the
 * 4-fold symmetric saltire/bowtie/diamond patterns real plates show.
 */
export function chladniField(x, y, modes) {
  let f = 0;
  for (const mode of modes) {
    const { m, n, weight } = mode;
    if (weight === 0) continue;
    const mPi = m * Math.PI;
    const nPi = n * Math.PI;
    f += 0.5 * weight * (
      Math.cos(mPi * x) * Math.cos(nPi * y) -
      Math.cos(nPi * x) * Math.cos(mPi * y)
    );
  }
  return f;
}
