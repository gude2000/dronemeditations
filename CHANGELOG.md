# Drone Meditations — Changelog

Release notes are a running record of what's shipped in each version. Each section becomes the "What's New in This Version" block when that version is submitted to the App Store.

---

## v1.1 — in progress

Features built after the v1.0 App Store submission was sent for review. This list is the working draft of the v1.1 "What's New" copy.

### New features

- **Replay × N timing envelope** — every voice's `Start after` / `Play duration` cycle can now repeat: Once (default) / × 2 / × 3 / × 5 / × 10 / ∞. The voice plays its [silent delay → fade-in → audible → fade-out] cycle the chosen number of times, then goes silent forever. Perfect for layered intro/outro patterns where one voice should bloom and recede repeatedly across a long meditation. (commit `70cc44f`)

- **Modal chord templates** — new **Modal** category in the chord picker with 9 entries: Ionian, Dorian, Phrygian, Lydian, Mixolydian, Aeolian, Locrian, Harmonic Minor, Melodic Minor. Each captures the mode's four most identifying degrees. When **Quantize to scale** is on, the snap cache fills with those same notes — so a pitch LFO arpeggiates *inside the mode* instead of wandering chromatically. (commit `346aa9d`)

- **Granular sampling** — Sample-waveform voices gain a **GRAINY** toggle. When on, continuous playback is replaced by a Hann-windowed grain scheduler that reads slices around a user-set position. Combined with the existing GRAIN row (size / density / jitter / pan spread) plus the new `pos` + `scan` sliders, this is full granular sampling: frozen Tibetan bowls shimmering forever, Basinski-style tape-decay clouds from any source, vowel sustains held without rhythm, geiger-counter ticks from a field recording. (commit `1d743fa`)

- **Haptics intensity** — the haptic-feedback toggle becomes a three-state cycle: **Off → Light → Heavy → Off**. Light halves the per-tap intensity for a barely-there pulse; Heavy is the original v1.0 scale. Persisted across launches. iOS only — Light = `0.5×`, Heavy = `1.0×` on the computed LFO-depth-derived intensity. (commit `2f690ae`)

- **Global BPM with delay sync** — a tempo field drives every voice's delay-time when that voice's timing is set to a musical division (½, ¼, ⅛, etc.). Default 80 BPM (resting-heart-rate territory, meditative without being sluggish). Changing the tempo recomputes every sync'd delay; Free-mode delays are left alone. iOS picker lives in the master row; web exposes it via tap-the-subtitle. (commits `2f690ae`, `ed09ca9`)

- **Stereo reverb** — the Schroeder JCRev now runs two independent chains (L + R) with slightly different comb and allpass lengths so the wet tail decorrelates naturally. The chorus's already-stereo output feeds the L/R chains directly. Wet output bypasses the dry-signal equal-power pan and goes straight to L/R — a hard-panned voice still spreads its reverb tail across both channels, the standard "the room you're in is always stereo" routing. (commit `5e0468f`)

- **Audio-thread CPU optimization** — per-sample reverb math is now skipped entirely when reverb mix is at 0, and per-sample delay math is skipped when both delay mix and feedback are negligible. Crackling on parameter drags during busy presets was largely caused by reverb running at full cost on voices that had it muted. On a typical preset with reverb active on 1-2 voices and muted on the rest, this saves ~9M ops/sec net — easily covering the extra cost of stereo reverb, plus some. (commit `5e0468f`)

- **Eight new showcase presets** in the Drone Artists category:
  - *Bansuri — Frozen Shimmer* — granular sampling on a Bansuri C4 sustain, position frozen at 35 % with low jitter
  - *Scriabin — Tape Decay* — granular sampling on the bundled mystic-piano sample, high scan jitter for Basinski-style cloud
  - *Vowel Cloud* — JG vocal sample held into a 300-ms-grain vowel cloud with ocean drift
  - *Galactic Dust* — tiny 40-ms grains of a cosmic synth sample at 28/s density, hard-panned
  - *Wide Cathedral* — four pure sines hard-panned with 9 s stereo reverb; the most obvious v1.1 stereo-reverb demo
  - *Lydian Bloom* — Lydian modal intervals + stereo reverb
  - *Pendulum Reverberation* — three voices on Wave/Sweep pan drift; stereo reverb keeps the room stationary while sources move
  - *Phrygian Stillness* — Phrygian modal + Replay × 3 × 4 voices × 60-s breath cycle = 18-min meditation built from the chord pill

  Presets gain four new optional voice fields — `bundledSampleName`, `sampleGranular`, `grainSamplePosFrac`, `grainSamplePosJitter` — so built-in presets can auto-load samples and configure granular settings. Old presets work unchanged. (commit `b83ce79`)

- **SwiftUI per-voice observation** — each `OscillatorStrip` now subscribes to its own `OscillatorVoice` `ObservableObject` instead of pulling state from the global view-model. Result: dragging a slider on OSC 1 no longer triggers `body` recomputation on OSC 2 / 3 / 4 — **~4× less SwiftUI work per slider frame** on a typical four-voice patch. Combined with the audio-thread bypass guards above, this should largely resolve the "crackling during parameter drags" symptom that came up after the v1.1 features piled on. (commit `f405d2c`)

- **Cycle-end reverb bloom** — the fade-out at the end of each timing cycle (one-shot ending, or every cycle when Replay × N > 1) goes from a flat 8-second linear ramp to a 10-second smoothstep with a trapezoidal wet-reverb bloom: wet ramps to 1.5× over the first 3 s, plateaus for 1.5 s, then settles back to 0.3× over the remaining 5.5 s while the gain envelope smoothstep-fades to 0. Every replay cycle now ends with the same "atmospheric stop bloom" character the global transport Stop produces — but per voice, per cycle. (commit `f3f4ff0`)

- **Faster fade-in on replay cycles** — the **first** cycle keeps the 8-second slow build (the meditative onset that sets the session mood); cycles **2+** use a 4-second fade-in so the rhythmic feel of Replay × N is preserved without the slow re-introduction repeating every time after a bloom-and-return. (commit `2de7c23`)

- **Gain-stage slider crackle fix** — reverb mix, delay mix, delay feedback, and chorus mix were read once per buffer (every 5 ms on iOS) and used as constants in the per-sample signal math. Dragging any of those sliders meant the gain stage stepped by whatever the slider moved in those 5 ms, which buzzed audibly. All four are now slewed per sample at the same ~15 ms time constant the LFO→filter mod uses; the bypass guards now check both target and slewed values so a drag back to 0 doesn't pop. (commit `e75134a`)

- **Delay-time + chorus-depth slider crackle fix** — `delayTapSamples` (Int) and `chSwing` (depth × maxSwing) were also per-buffer constants. Dragging the delay TIME slider jumped the read index by N samples per buffer; dragging the chorus DEPTH slider stepped the LFO swing range. Now both slew per sample: delay tap on a slower 200 ms time constant (slewing tap position IS a small Doppler shift, faster slew = louder pitch glide during drag), with linear-interpolation fractional reads from the buffer; chorus depth on the same 15 ms gain-stage constant. (commit `6956c47`)

- **Drive + FM index slider crackle fix** — both were per-buffer constants too. Dragging DRIVE stepped the tanh saturation curve; dragging FM INDEX stepped the per-sample carrier phase increment by hundreds of Hz (the loudest possible audio click). Now slewed per sample at the gain-stage 15 ms constant. (commit `f437717`)

- **Fade-out gain envelope back to linear** — the 10-second smoothstep fade introduced with the cycle-bloom landed felt abrupt because smoothstep stays at almost full gain for the first 30 % of the fade. Linear fade brings back the v1.0 perceived-continuous taper. Bloom shape softened too: peak 1.3 instead of 1.5, tail 0.5 instead of 0.3 — feels like a tail extension rather than a swell now. (commit `f437717`)

- **Removed run-loop hop from per-voice sync** — the Combine sink that mirrors `$oscillators` into the per-voice `OscillatorVoice` boxes was scheduled `.receive(on: RunLoop.main)`. Slider drags fire @Published 60+ times per second, queuing a run-loop hop per tick measurably backed up the main thread. The sink work is cheap and runs on the same main-actor that publishes, so it's now synchronous — faster and correct. (commit `f437717`)

- **User-preset save now captures drift** — saving a user preset (a full-session ⭐ save) was dropping the per-voice drift config: pitch mode, pan mode, amount, period, and the **Quantize to scale** toggle. (Voice presets — the per-strip ⭐ saves — were already saving drift correctly.) Fixed: `UserPreset.Voice` gains an optional `drift` field, the save site passes `o.drift`, the load site restores both drift state AND pushes `pitchQuantizeToScale` into the audio engine + recomputes the quantize cache so the snap takes effect immediately. Old saves load fine — they get the per-voice default (no drift, quantize off) which is what they had at save time. Morph apply path also forwards drift now, so morphing between a preset with quantize-on and one with it off behaves correctly. (commit `2e5bb46`)

### Web app parity

- v1.0 features now run on the web app too: Replay × N in the ⏱ Timing menu, Randomize-all dice + Undo at the end of the OSC nav row, modal chord templates in the chord picker, global BPM with delay sync. (commits `67e5e6d`, `346aa9d`, `ed09ca9`)

### Deferred to v1.2

- **Granular sampling on web** — the iOS feature reads grains from a loaded sample. The web grain scheduler uses native WebAudio AudioParam ramps on a pre-recorded pink-noise buffer; switching it to read from a user-loaded sample requires an architecture rework that doesn't fit a quick parity port.
- **LFO rate sync** — per-LFO `Sync` toggle that locks rate to a BPM division (½, ¼, ⅛…). Useful but unproven need for a drone synth; revisit if users ask.

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
