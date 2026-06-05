# Drone Meditations — Roadmap

Forward-looking feature ideas not yet shipped. Versions follow Apple's
marketing-version convention: bumps only when there's something
user-facing worth a release-note paragraph. Bug-fix-only builds stay
on the current version with an incremented build number (see
`CHANGELOG.md` for the build history).

---

## Shipped

### v1.0 launch (build 11) — 5th LFO + atmospheric polish ✅

Fifth LFO per voice with a dedicated nine-target set (grain size /
density / jitter / spread; delay time / feedback / mix; reverb decay /
mix). 20 multi-target modulators per patch. Plus gentler stop bloom,
the pause/stop fade hard-cut fix, and BPM + metronome lifted to the
header (was buried below four oscillator strips). This was originally
planned as v1.1 but rolled into v1.0 build 11 — build 10 was
withdrawn from App Store review before going live, and these
additions land on top in the new launch build.

Final shape differed slightly from the original v1.1 plan below:

- **No subdivision-lock picker on LFO 5 itself** — LFOs 1–5 all share
  the existing per-LFO BPM-syncable rate, so the LFO 5 grain-density
  modulation naturally rides the global tempo via the LFO's own rate
  lock rather than a separate density-subdivision picker. Simpler UI,
  same end result for "stuttering grain pulses at 1/8."
- **Position / Scan range / OVL targets dropped from MVP** — landed
  with the four grain DSP targets (size, density, jitter, spread)
  plus a dedicated FX target set (delay time/feedback/mix, reverb
  decay/mix). Position / scan / overlap envelopes are valid v1.x
  follow-ups if there's demand.
- **`.dronepreset` schema bump deferred** — older 4-LFO presets load
  with LFO 5 disabled via a pad-on-touch helper on both platforms,
  no format-version bump required.

See `CHANGELOG.md` for the full v1.1 release notes.

---

## v1.x ideas (unscheduled)

- **LFO 5 sample-granular targets** — Position, Scan range, and per-
  voice Overlap on/off as additional LFO 5 chips (originally part of
  the v1.1 plan, deferred). Would unlock scanning-over-time textures
  and rhythmic grain-overlap gating.
