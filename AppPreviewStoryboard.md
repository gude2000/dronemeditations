# App Preview Video Storyboard — Drone Meditations

A 30-second App Store preview video. Massive lift for an unknown
developer — Apple users who watch the preview convert at ~3-4× the
rate of users who only see screenshots.

## Specs

| Field | Value |
|---|---|
| Duration | **Up to 30 seconds** (we'll use the full 30) |
| iPhone format | **1080×1920** (portrait) or **886×1920** (preferred portrait) — Apple specs at <https://help.apple.com/app-store-connect/#/dev4e413fcb8> |
| iPad format | **1200×1600** (portrait) or **1600×1200** (landscape) |
| Frame rate | 30 fps |
| Codec | H.264, baseline 3.0 or higher |
| File size | <500 MB (we'll be way under) |
| Audio | Must be present, ducked appropriately — Apple checks |
| Captions | Optional, but recommended for sound-off viewing |

## Recording method

**iOS Simulator route** (easiest):
1. Boot iPhone 17 Pro Max simulator
2. Run app with `xcrun simctl io booted recordVideo screenshots/preview-raw.mov`
3. Drive the app manually following the cut list below
4. Stop recording with Ctrl+C
5. Crop / cut / add captions in iMovie or Final Cut

**Physical device route** (better audio, more authentic):
1. Connect iPhone to Mac via cable
2. Open QuickTime Player → File → New Movie Recording
3. Switch the camera and mic source to the connected iPhone
4. Record audio + screen
5. Edit in iMovie / Final Cut

**Audio choice**: Use the actual app audio at low volume (drone preset
playing through the recording) — Apple users hear it and immediately
understand it's a meditation/synth app, not a productivity tool.

## Cut list

Total: 30 s. Each section is a single take if possible (Apple penalizes
choppy edits).

### Sec 0:00–0:03 — Cold open

**Action**: App is already open, fullscreen Chladni in Performance mode,
pattern slowly morphing.
**Audio**: Quiet sub-bass drone (110 Hz sine), ~30 % volume.
**On-screen text**: None — let the visual carry it. Apple's auto-play
preview starts here; the first 2 seconds are the hook.

### Sec 0:03–0:06 — Reveal the brand

**Action**: Fade in a single text overlay over the Chladni:
> **Drone Meditations**
> A drone synthesizer for ambient & meditation

Use the rounded SF font, white, semi-transparent. Hold 3 seconds.

### Sec 0:06–0:10 — Show the synth depth

**Action**: Tap to show controls. Camera pans over the 4 oscillator
strips, then zooms in on one strip showing GRAIN row, FILTER row,
4 LFO targets.
**Audio**: Same drone continues; granular crackle layer fades in.
**Text overlay** (bottom strip, subtle):
> 4 oscillators · granular · 4 LFOs · 6 tuning systems

### Sec 0:10–0:15 — Show the preset library

**Action**: Tap PRESET pill → Preset picker opens. Scroll through
Drone Artists category — Oliveros, Riley, Radigue, Stars of the Lid,
Sunn O))), Basinski, Niblock visible. Tap "Basinski — Tape Decay Cycle".
**Audio**: Brief transition pop, then the new preset's piano-loop
character starts playing through the chorus.
**Text overlay**:
> 80+ presets · including 28 Drone Artists tributes

### Sec 0:15–0:21 — Show the auto-morph (the wow moment)

**Action**: Tap MORPH pill. From = "Basinski — Tape Decay Cycle".
To = "Oliveros — Deep A Resonance". Duration chip: 5 min. Tap Play.
Cut to fast-forward (2-4× speed) showing the slider crawling from
0% → 50% → 100% over a few seconds.
**Audio**: Time-stretched mix of the two presets blending.
**Text overlay**:
> Morph between any two presets over time

### Sec 0:21–0:25 — Back to cymatics

**Action**: Dismiss the morph sheet. Tap hexagon icon if cymatics
isn't already on. Tap to hide controls — fullscreen Chladni again,
now showing the Oliveros-end pattern. Slowly pinch zoom in.
**Audio**: The current morph state (mostly Oliveros A drone now).
**Text overlay**:
> Physically-calibrated live cymatics

### Sec 0:25–0:30 — End card

**Action**: Fade Chladni to dark. Center logo + tagline + URL.
**Audio**: Drone slowly fades out to silence.
**Text overlay** (centered, stacked):
> **Drone Meditations**
> $14.99 · iOS + iPad
> dronemeditations.com

## Production tips

- **Don't talk over the audio.** Apple's App Store review will penalize
  voiceovers that aren't subtitled. Let the sound + on-screen text
  carry the message.
- **Keep text legible** — minimum 28pt at the rendered size, semi-bold
  rounded font, white on dark with light shadow.
- **No marketing copy that contradicts the App Store rules** — avoid
  "best", "guaranteed", "instant relief from anxiety", any medical
  claims. Stick to feature descriptions and aesthetic claims.
- **Test on a real device before uploading.** App Store Connect rejects
  videos with audio sync issues, frozen frames, or black frames at the
  start.
- **End card matters most after the hook** — the first 2 seconds bring
  them in, the end card decides whether they tap Install.

## Optional: 15-second cut

If you want a tighter version (App Store accepts videos as short as
15 seconds), drop sections 2 and 5, keeping:

- 0:00–0:03 Cold open
- 0:03–0:07 Show synth depth
- 0:07–0:11 Preset library tap
- 0:11–0:15 End card

Tighter, more punchy. Better for paid social ads if you ever run them.

## Estimated production time

- First-time recording with iMovie: **2-3 hours** (mostly tweaking)
- With Final Cut Pro or DaVinci Resolve: **1-2 hours**
- Subsequent cuts (different lengths, different focus): **30 min each**

## After it's recorded

1. Export at the App Store specs above
2. App Store Connect → Drone Meditations → 1.0 Prepare for Submission
3. Scroll to "App Previews and Screenshots" section
4. Upload one preview per device family (iPhone, iPad)
5. Apple's review will check the video plays correctly during the
   normal review process — no separate review step
