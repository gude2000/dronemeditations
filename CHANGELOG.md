# Drone Meditations — Changelog

Release notes are a running record of what's shipped in each version. Each section becomes the "What's New in This Version" block when that version is submitted to the App Store.

---

## v1.1 — in progress

Features built after the v1.0 App Store submission was sent for review. This list is the working draft of the v1.1 "What's New" copy.

### New features

- **Replay × N timing envelope** — every voice's `Start after` / `Play duration` cycle can now repeat: Once (default) / × 2 / × 3 / × 5 / × 10 / ∞. The voice plays its [silent delay → fade-in → audible → fade-out] cycle the chosen number of times, then goes silent forever. Perfect for layered intro/outro patterns where one voice should bloom and recede repeatedly across a long meditation. (commit `70cc44f`)

- **Modal chord templates** — new **Modal** category in the chord picker with 9 entries: Ionian, Dorian, Phrygian, Lydian, Mixolydian, Aeolian, Locrian, Harmonic Minor, Melodic Minor. Each captures the mode's four most identifying degrees. When **Quantize to scale** is on, the snap cache fills with those same notes — so a pitch LFO arpeggiates *inside the mode* instead of wandering chromatically. (commit `346aa9d`)

- **Granular sampling** — Sample-waveform voices gain a **GRAINY** toggle. When on, continuous playback is replaced by a Hann-windowed grain scheduler that reads slices around a user-set position. Combined with the existing GRAIN row (size / density / jitter / pan spread) plus the new `pos` + `scan` sliders, this is full granular sampling: frozen Tibetan bowls shimmering forever, Basinski-style tape-decay clouds from any source, vowel sustains held without rhythm, geiger-counter ticks from a field recording. (commit `1d743fa`)

### Web app parity

- All v1.0 features now run on the web app too: Replay × N in the ⏱ Timing menu, Randomize-all dice + Undo at the end of the OSC nav row, modal chord templates in the chord picker. (commits `67e5e6d`, `346aa9d`)

### Known queue (not yet implemented)

- Haptics on/off + Light/Heavy intensity
- Preset BPM (with optional delay-time sync)

---

## v1.0 — submitted to App Store on 2026-05-28

The first public release. Submitted as build 8 of the marketing 1.0 line (TestFlight history: 1.0 builds 1–6 → 1.1 builds 7–8 → relabeled back to 1.0 for launch).

### Synth architecture

- Four oscillator voices, each with its own signal chain: waveform (sine / triangle / sawtooth / square / white-noise / pink-noise / granular-pink / loaded sample), state-variable filter (LP / HP / BP), drive (tanh saturation), four LFOs, FM, stereo chorus, mono / stereo / ping-pong delay, Schroeder reverb.
- **Multi-target LFOs**: each LFO can drive pan + amplitude + cutoff + Q + pitch + FM-index simultaneously.
- **Quantize to scale**: per-voice toggle that snaps the post-modulation pitch to chord notes.
- **80+ curated presets** including artist tributes (Pauline Oliveros, Éliane Radigue, Stars of the Lid, Sunn O))), William Basinski, Phill Niblock, Harold Budd, Alice Coltrane, Charlemagne Palestine, Keiji Haino, Earth, Nurse With Wound) plus binaural / cymatic / spectral / drift-showcase categories.

### Tunings

- 12-TET, 24-TET, 72-TET, whole-tone, just intonation, Pythagorean, Harrison JI, Partch 43-tone, Wendy Carlos α / β / γ, φ-tuned (13-step golden octave). Every chord template snaps to the active tuning.

### Tune to Room

- Live microphone pitch detection (YIN algorithm) detects a sustained acoustic tone — singing bowl, voice, tuning fork — and snaps the chord generator's root to that exact frequency. The last detected pitch is held on screen so users don't race the readout.

### Cymatics

- Physically-calibrated Chladni-plate renderer, fit from 17 frames of brusspup demo footage. Patterns respond to every voice's live pitch including LFO modulation. Pop-out window + fullscreen Perform mode for installations.

### Visualizers

- Cymatic (default) and Spectrum (FFT bars) — toggle via header icons.

### Meditation Journeys

- 20+ scripted multi-stage sessions that auto-advance presets + drift over a fixed duration: Sundown, Awakening, Floating, Crystal Cave, Spiral Descent, Tibetan Bowl, more. Each fades gently at the end.

### Drift

- Per-voice slow generative motion. Pitch modes: Static / Up / Down / Up-Down / Down-Up / Wave / Ocean (±¼-semi / 90 s) / Glacial. Pan modes parallel. Amount + Period overrides per voice.

### Morph

- Pick two presets, drag the slider to crossfade between them — every per-voice parameter interpolates. Auto-morph timer: 30 s to 60 min.

### Recording

- Master output → **24-bit WAV** (DAW-ready, bit-perfect) **+ AAC M4A sidecar** (~10× smaller for sharing). Both files mastered with -16 dBFS RMS gain + 2 s fade-in / 4 s fade-out + metadata, saved to `Drone Meditations/Recordings/` in the Files app.

### Polish

- Click-free pause and stop with atmospheric reverb-bloom fades on iOS hardware.
- 5-card first-launch onboarding tour.
- Per-voice ⭐ preset library + per-voice 🎲 randomize.
- Global 🎲 Randomize-all + ↶ Undo at the end of the OSC pill row.
- Sample play-window + per-loop fade-in / fade-out.
- iPad single-row transport with 56-pt play button.

### Performance

- Granular: per-sample `cos` replaced by 1024-entry Hann LUT; `Double.random` replaced by per-voice xorshift64* PRNG. ~10× faster grain windowing, ~20× faster RNG.
- Chladni: 4 per-mode cos arrays of size `grid` precomputed once per frame; inner cell loop becomes 4 array reads + 2 multiplies + 1 subtract. ~140× fewer `cos` calls per frame (~15M/s → ~107k/s on the main thread).
- LFO → filter modulation: per-sample slew with 15-ms time constant + biquad coefficients recomputed every 16 samples. Eliminates the click on square / S&H / ramp LFO shapes targeting cutoff or Q.

### Privacy

- Zero data collection. No accounts. No network. No tracking. Microphone is processed live for Tune to Room only, never recorded or transmitted.
