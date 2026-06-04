# Drone Meditations — Roadmap

Forward-looking feature ideas not yet shipped. Versions follow Apple's
marketing-version convention: bumps only when there's something
user-facing worth a release-note paragraph. Bug-fix-only builds stay
on the current version with an incremented build number (see
`CHANGELOG.md` for the build history).

---

## v1.1 — modulation expansion

### 5th LFO with granular + subdivision targets

A fifth LFO per voice, sitting in the same row layout as LFOs 1–4 but
with a dedicated target set for the **granular engine** and rhythmic
subdivisions:

**Targets**

- Grain size (ms)
- Grain density (Hz), with an optional **musical subdivision lock**
  (½, ¼, ¼t, ⅛, ⅛t, 1/16, 1/16t, 1/32, 1/32t) that mirrors the
  existing per-voice density chip — the LFO modulates around the
  quantized base rate
- Grain jitter
- Pan spread
- Position (for sample-granular voices)
- Scan range (for sample-granular voices)
- Per-voice overlap on/off envelope (gates the OVL toggle)

**Why it matters**

- LFOs 1–4 currently can drive *pitch / amp / pan / cutoff / Q /
  FM index / fx-mix*. None of those touch the grain scheduler. To
  get rhythmic grain modulation today you have to script density
  changes manually or rely on the BPM-quantized density chip's
  steady-state value.
- A 5th LFO with shape choices (esp. S&H, triangle, square) driving
  grain density at a musical subdivision unlocks **stuttering pulse
  textures, grain-rate accelerandos, Steve Reich-style phasing
  between two grain clouds at different rates**.
- Bumps modulator count from 16 to **20 per patch** (5 LFOs × 4
  voices), which is the kind of headline number that justifies a
  v1.1 callout in App Store release notes.

**Scope**

- iOS: add `LFO5` slot in the per-voice control area + corresponding
  `LfoState` extension + new `LFOTarget` cases for the granular
  parameters. Wire into `Voice.swift`'s grain scheduler.
- Web: mirror — add 5th LFO row in `voice.js` UI + corresponding
  modulation paths in `audio.js`. Same target enum string.
- Preset format: extend `.dronepreset` schema with optional `lfos[4]`
  entry; older presets without it default to disabled. Bump the
  preset-format minor version to 2.
- `gen_swift.py`: extend the emitter to recognize LFO5 from the
  JSON envelope.
- Documentation: update the manual + AppStoreListing.md "Sixteen
  multi-target LFOs" copy to **"Twenty modulators per patch"**.

**Implementation notes / gotchas**

- The existing per-LFO rate-sync UI is already shape-aware. Reuse it
  for LFO5; the density-subdivision picker is a separate row only
  when the active target is **grain density**.
- Granular targets need a slew (probably ~50 ms) on the modulated
  value before it hits the scheduler to avoid grain-rate zipper noise
  when fast LFO shapes flip density.
- S&H driving grain density at quantize=on should snap to the **next
  bar boundary** at S&H step time, not interpolate. Matches how the
  existing grain density chip behaves.

---

## v1.x ideas (unscheduled)

(Add backlog items here as they come up.)
