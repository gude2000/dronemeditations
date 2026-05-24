# Drone Meditations — Web

Browser-based drone synth with 4 freely-tunable oscillators, microtonal tunings,
binaural-beat presets, and real-time Chladni-pattern visualization.

Built with vanilla HTML + CSS + JavaScript (ES modules). No build step.

## Running locally

Web Audio requires the page to be served (not opened as `file://`).
Any local server works; the included script uses `npx serve`:

```bash
cd web
npm start
# → open http://localhost:5173
```

Alternatives:
- `python3 -m http.server 5173` from inside the `web/` directory
- VS Code's "Live Server" extension

## Project layout

```
web/
├── index.html          Single-page entry
├── styles.css          All styling (dark, glassy)
└── js/
    ├── main.js         Bootstrap, app state, event wiring
    ├── audio.js        AudioEngine (Web Audio API + 4 voices)
    ├── music.js        Waveforms, tunings, chord catalog, presets
    ├── ui.js           Render functions for controls + modal sheets
    └── visualizations.js  Canvas blob background + Chladni pattern
```

## Notes

- **Headphones recommended.** Binaural beats only work with stereo separation
  (different tone in each ear). The app still sounds good on speakers, but
  binaural presets won't produce the difference-frequency effect.
- **First user interaction starts audio.** Browsers require a click/tap before
  `AudioContext` can produce sound; the Play button handles this transparently.
- **Background audio in browsers is limited.** If you need rock-solid
  screen-locked playback for long sessions, use the native iOS app at the
  repo root.
