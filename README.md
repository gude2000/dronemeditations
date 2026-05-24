# Drone Meditations

A 4-oscillator drone synthesizer for meditation and binaural exploration.
Two implementations sharing one design:

- **`web/`** — Web Audio app (vanilla HTML / CSS / ES modules, no build step).
  This is what gets deployed to [dronemeditations.com](https://dronemeditations.com).
- **`DroneMeditations/` + `DroneMeditations.xcodeproj/`** — Native iOS / iPadOS app
  (SwiftUI + AVAudioEngine). Used for screen-locked playback where WebKit's
  background-audio limits get in the way.

## Features

### 4 voices, each with
- Selectable waveform — **sine, triangle, sawtooth, square**
- Frequency 20 Hz – 2 kHz, log-scale slider with tap-to-edit (2-decimal precision)
- Per-voice biquad **filter** — LP / HP / BP, log-scale cutoff (20 Hz – 8 kHz), Q (0.3–20)
- **3 LFOs** per voice, each with:
  - Shape: **sine** or **sample-and-hold**
  - Target: **pan**, **amp**, or **cutoff** (independently assignable)
  - Rate 0.02 – 8 Hz (log slider), depth 0 – 1
  - Multiple LFOs can target the same parameter and sum
- Stereo pan, level, solo, mute
- **−0.1 dB limiter** on the master bus to prevent clipping

### Music theory
- **All 12 keys × 6 octaves**
- **7 tuning systems**: 12-TET, 24-TET (quartertone), 72-TET (microtonal), Whole Tone,
  Just Intonation, Pythagorean, Phi (φ-octave / 13)
- **~35 chord types** in 5 categories: triads & 7ths, extensions, symmetric, quartal,
  microtonal (phi steps, 72-TET neutral, Bohlen-Pierce, etc.)
- **~22 presets**:
  - 2-tone binaural: Delta 4 Hz, Theta 6 Hz, Schumann 7.83 Hz, Alpha 10 Hz, Beta 18 Hz, Gamma 40 Hz
  - 3-tone and 4-tone binaural with carrier-and-beat combinations
  - Natural resonance: OM 136.1 Hz, Moon 210.42 Hz, Sun 126.22 Hz, Earth (Schumann)
  - Solfeggio: 396 / 417 / 528 / 639 / 741 / 852 Hz

### Visualization
- Drifting blob field — one organic blob per oscillator, hue mapped to frequency band
- Real-time **Chladni nodal pattern** derived from the active voice frequencies
- Tap anywhere on the canvas to show / hide controls

### Transport
- Play / pause / stop with session timers from 5 min up to 1 hour, or open-ended

## Running the web app

Web Audio requires a served page (not `file://`). Inside `web/`:

```bash
cd web
npm start   # → http://localhost:5173
```

Alternatives: `python3 -m http.server 5173`, VS Code Live Server, etc.

## Running the iOS app

```bash
open DroneMeditations.xcodeproj
```
Build & run on the iPhone simulator (no signing needed) or an attached device
(set your team in the target's Signing & Capabilities tab).

## Notes
- **Binaural beats require headphones.** Without stereo separation the brain
  doesn't perceive the difference-frequency beating.
- **First gesture starts audio** — browsers won't let `AudioContext` produce sound
  until the user clicks something. The Play button handles this transparently.
- For long screen-locked sessions, prefer the native iOS app — WKWebView's
  background-audio support is more constrained than native AVAudioEngine.
