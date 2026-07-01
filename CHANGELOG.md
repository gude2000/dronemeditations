# Drone Meditations — Changelog

Release notes are a running record of what's shipped in each version. Each section becomes the "What's New in This Version" block when that version is submitted to the App Store.

---

## v1.1 (build 15) — Preset-load reliability

*Supersedes builds 13–14 (same 1.1 feature set + What's New). Reliability fixes found in testing.*

### Fixes

- **Loading a preset resets the chord mode.** Bundled presets are raw frequencies with no chord of their own, so the previous patch's *mode* used to carry over — e.g. Lydian Dream → Solfeggio updated the key but stayed "Lydian." Every preset load now snaps the chord template to **Major** unless the preset names its own chord (INIT sets "Major" explicitly). Web + iOS.

- **Loading a preset no longer inherits the previous patch's sound.** The built-in preset picker (`applyPreset`) applied each voice's effects with `if let`, so any parameter the incoming preset didn't specify — drive, FM, waveform, filter, delay feedback, granular — kept the value from the patch you were just on. Switching from a "driven"/distorted patch to a simpler one left the distortion stuck until the app was relaunched. Both load paths (`applyPreset` for bundled presets and `loadUserPreset` for saved/shared presets) now reset every voice's full DSP chain to defaults **before** applying the preset's own fields, so every load starts from a clean slate — matching a fresh launch. Your per-voice quantize-to-scale toggle is deliberately preserved.
- **Automation timeline no longer carries over to presets that have none.** Loading a built-in preset (INIT, Solfeggio, binaural, …) left the previous patch's Automation Timeline in place — so its chord-changes/fades kept sequencing over the new preset (INIT would seem to load in the wrong key, not clean). `applyPreset` now clears the timeline and stops the live dispatcher; `loadUserPreset` also stops any dispatcher still firing the old timeline mid-playback. INIT is once again a true rescue gesture.
- **INIT snaps the chord pill to A Major.** INIT's voicing (A · E · A · C♯) *is* A major, but the chord template used to inherit the previous patch's mode — so the pill could read "A minor" over an A-major sound. Presets can now carry an optional `chordId`; INIT sets "Major" so the label matches. Other presets are unchanged (they still keep the current template).
- **Chord slug→name safety net for cross-platform presets (iOS import).** `.dronepreset` files exported by the web app before the slug→name export fix carried the chord *slug* (`"lydian"`), which iOS matched by *name* (`"Lydian"`) — so a G Lydian patch loaded as G Major (key right, mode lost). The iOS importer now translates web chord slugs to names for both the base chord and any automation chord-change events, so **any** web export — old or new — resolves the right key/mode without a re-export.

---

## v1.1 (build 13) — Automation Timeline

*The first post-launch feature update. A per-patch, time-based event sequencer on iOS — plus a reusable setups library, and full automation edit + playback on the web.*

### What's New in This Version  *(App Store copy)*

- **Automation Timeline.** A new AUTOMATION pill opens a per-patch sequencer. Schedule chord progressions, fades, waveform/sample switches, level and mute changes, and LFO rate/depth moves at bar + beat positions. Chord changes transpose your voicing — so layered drones keep their character — and positions are tempo-relative, so changing the BPM rescales the whole phrase in proportion. Loop a passage a set number of times, or let it hold until you stop.
- **Automation setups.** Save a timeline under a name and load it onto any patch later — a reusable library of favorite progressions and modulation builds.
- **BPM & metronome in the header.** The tempo readout and metronome toggle now live in the always-visible top row — no more hunting through the master strip, especially in iPhone landscape.
- **Fixes:** imported presets keep their automation; preset-import messages are clearer.
- The free web app at dronemeditations.com has the full Automation Timeline too, so patches animate identically on the web.

---

### Web — automation playback (iOS↔web parity)

The web app now **plays** the Automation Timeline, not just stores it. A patch shared from iOS animates its scheduled events — chord progressions, fades, level/mute, waveform/sample switches, and LFO rate/depth envelopes — exactly as it does in the app.

#### Detail

- **Web Automation playback.** `web/js/main.js` gains an `automationPlayer` that mirrors the native `AutomationDispatcher` + `DroneViewModel.dispatchAutomation`:
  - Runs on its own ~33 Hz clock (independent of the coarse 250 ms UI ticker) so beat-precise events land.
  - **Tempo-relative**: each event's `gridSixteenth` resolves to seconds at the live BPM at Play, so changing tempo keeps the structure in proportion (same fix as iOS).
  - Chord changes **transpose** each voice relative to a captured baseline (preserving non-triadic voicings) rather than respelling a triad; honours the Up / Down / Nearest direction.
  - Captures a baseline of the patch on first Play and restores it on every replay / Stop→Play so loops start clean.
  - Loop length (`totalBars × secPerBar`) + repeat count (`loopCount`) with the same offset-accumulation wrap as the dispatcher.
- Tolerant parsing of the Swift-Codable timeline shape (both `"all"`/`{all:{}}` and `{oscillator:{_0:i}}` voice forms; string and object no-payload action encodings). iOS chord IDs (names) are matched against web slugs by id-or-name.

### Notes

- Sample-waveform events resolve the named bundled sample from `./samples/index.json` (best-effort; falls back to flipping waveform mode if the name isn't found in the web library).
- **Full web editor.** The web app now also has the AUTOMATION pill, event-list sheet, and bar/beat event editor (all 8 action types) — build and edit timelines in the browser, not just play them. Events are written in the iOS-Codable shape (event `id` as a real **UUID**, `VoiceFilter.all` as `{"all":{}}`, chord NAME as `chordId`) so they decode on iOS and round-trip through `.dronepreset` identically. The exporter also **normalizes older/legacy web timelines** (bad ids → UUID, `"all"` → `{"all":{}}`) so already-saved presets export iOS-valid.
- **Automation edits auto-sync to the loaded preset (web).** When a user-library preset is loaded, editing its timeline writes straight back into that stored preset — so Share/export always ships the *current* timeline with no manual "Save current…" first. Tracked via `state.activeUserPresetId`.
- **Fixed: cross-platform chord id mismatch changed the notes (web↔iOS).** The web stores `chordId` as a slug (`"lydian"`); iOS resolves chords by name (`"Lydian"`). A slug iOS couldn't match made it fall back to the wrong chord — inaudible for static drones (per-voice frequencies transfer directly) but it changed the **quantize-to-scale** pitches, which follow the resolved chord's scale (e.g. JG Lydian Dream). Fix (web-side, no iOS rebuild): the `.dronepreset` exporter translates `chordId` slug→name so iOS matches, and the importer normalizes name-or-slug→slug so the web still resolves it. Re-export any affected preset to pick up the fix.
- **iOS cymatics now render on the GPU.** The Chladni field was a CPU SwiftUI `Canvas` filling a 140×140 grid of rectangles at 24 fps — blockier and less lively than the web. It's now a Metal fragment shader (`Chladni.metal`) applied via SwiftUI `.colorEffect`: per-pixel and sharp (with the web's tighter `mag * 9` node threshold), ~30 fps, and lower CPU (frees the audio render thread). Modes are passed as eight `float4` args (m, n, weight, hue) with an opaque additive output under `.blendMode(.plusLighter)`. Matches the web's crispness. Sand grains stay on a Canvas overlay.
- **Automation setups library (web + iOS).** A reusable, named library of Automation Timelines. In the AUTOMATION sheet, **Save current…** stores the timeline under a name; the **Saved setups** list loads any of them onto the current patch (independent of the sound), with delete via swipe (iOS) / ✕ (web). Per-device on each platform. Web: `dronemeditations:automation-setups` in localStorage + `saveAutomationSetup`/`loadAutomationSetup`/`deleteAutomationSetup` dispatch. iOS: `AutomationSetup` + `AutomationSetupStore` (UserDefaults JSON, mirroring `VoicePresetStore`) + VM methods. (iOS side rides the next build.)
- **Clean import result on iOS.** The `.dronepreset` import alert now shows a friendly "Couldn't import … — the file appears to be damaged, or was made with a newer version" (or the specific version-mismatch reason) instead of the raw URL / JSON-keys / decode-internals debug dump. (Rides the next iOS build.)
- **Fixed: imported presets silently lost their automation (iOS).** `UserPresetSharing.importPreset` decoded the timeline into `p.automation` but rebuilt the re-id'd `UserPreset` without it (every field *except* `automation`), so the stored preset came in with `automation = nil`. Now carries `automation: p.automation` through. Import and export were asymmetric — export encodes the whole `UserPreset` via Codable (automation included), only import dropped it. (Rides the next iOS build.)
- Cache-bust: `main.js?v=49`, `ui.js?v=45`, `preset-sharing.js?v=44`, `styles.css?v=14`.

---

### iOS — Automation Timeline (implementation detail)

Per-patch time-based event automation. Behind a new **AUTOMATION** pill in the top control row (right after PRESET), tap to open a sheet that lists scheduled events by time and lets you edit, add, or delete them.

> Note: the original spec below shipped with later refinements — 8 event types (adds **LFO rate** and **LFO depth**), **bar + beat** entry on a 1/16 grid, **tempo-relative** positions (events resolve to seconds at the live BPM via `gridSixteenth`, so changing tempo rescales the timeline), chord-change **Direction** (Up/Down/Nearest) and **Duration** auto-advance, and **Length** (bars) + **Repeat** count replacing the seconds-based duration/loop. Chord changes **transpose** voices relative to a captured baseline rather than respelling a triad.

### New

- **Automation Timeline.** Schedule events at time markers within a patch. Six event types:
  - **Chord change** — switch key + chord (e.g. A min7 → D dorian at 5:00). Patch-wide.
  - **Fade in** / **Fade out** — 0–15 s amplitude ramp on the selected voice(s). Overrides the existing per-voice timing envelope when both are present (locked decision #4).
  - **Waveform** — discrete sine / triangle / sawtooth / square / noise / granular / sample switch.
  - **Level** — set voice amplitude to a specific value (0–100%).
  - **Mute toggle** — invert mute state.
  
  Each event has a **Voice** filter: `All voices` or `OSC 1-4`. `All voices` events affect every voice regardless of fade/mute state (locked decision #3).
  
- **Manual stop default.** Timeline duration defaults to 0 = "until manual stop" (locked decision #2) — events fire once and the timeline ends when you tap Stop. Setting a positive duration enables the **Loop** toggle, which wraps back to event 0 at the end. Dispatcher uses an internal offset to wrap without resetting the engine's `transportElapsed`.
- **Journey vs Automation.** Two separate features with separate use cases (locked decision #5). **Journey** scripts a sequence of whole-preset swaps over multi-stage arcs; **Automation** modifies a single preset's parameters over time. The manual section documents both.

### Architecture

- **`Models/AutomationTimeline.swift`** — `AutomationEvent` (id, timeSec, voice, action), `VoiceFilter` (.all / .oscillator(i)), `AutomationAction` (six cases), `AutomationTimeline` (totalDurationSec, loop, events). Schema version 1, soft cap 50 events, hard cap 200.
- **`Audio/AutomationDispatcher.swift`** — `@MainActor` Timer-based scheduler polling `engine.transportElapsed` at ~30 Hz on `.common` run-loop mode. Snapshots a sorted event list at `start()`, walks the index forward as elapsed passes each `timeSec`. `pause()` freezes; `reset()` clears. Loop wrap via `loopOffsetSec` accumulation.
- **`ViewModels/DroneViewModel.swift`** — `@Published var automation` + `private automationDispatcher`. `controller.$state` Combine sink calls `handleAutomationStateChange` → `start` / `pause` / `reset`. `dispatchAutomation(_:)` fans out actions to existing setters: chord events call `setKey` + `setChord`, fade events kick off per-voice async amplitude ramp Tasks with a generation counter (cancels stale ramps on Stop or new event pre-emption), waveform / level / mute call `setWaveform` / `setAmplitude` / `toggleMute`.

### UI

- **`Views/AutomationSheetView.swift`** — top-level sheet. Duration menu (manual-stop through 60 min presets). Loop toggle (disabled when duration is 0). Event list with monospace time + action summary + voice filter. Swipe to delete. **+** button creates new events. Soft-cap warning banner past 50 events.
- **`Views/AutomationEventEditorView.swift`** — per-event sheet. Min + sec Steppers. Voice picker (All / OSC 1-4). Action type picker (six choices). Type-specific fields below: chord (Key + Chord menus sectioned by category), fade (0-15s Slider), waveform (Waveform menu), level (0-100% Slider), mute toggle (no fields, just a footnote). Delete button only on existing events.
- **`Views/ControlsOverlay.swift`** — new `AUTOMATION` pill inserted right after PRESET in both portrait + compact-landscape header paths (locked decision #1). Pill shows "Off" or "N events".

### Persistence

- **`Models/UserPreset.swift`** — optional `automation: AutomationTimeline?` field. Emitted on save only when timeline is non-empty (older readers see no field for patches without it). nil on load → empty timeline.
- **`.dronepreset` round-trip.** Field is preserved through file sharing on both iOS and web. iOS-edited automation survives a save-on-web → share-back-to-iOS round trip even though the web doesn't surface an editor in v1.1.
- **iCloud sync.** Automation rides the existing NSUbiquitousKeyValueStore mirror; no extra wiring.

### Web

- **Schema preservation only.** `web/js/main.js` reads + writes the `automation` field in the `.dronepreset` envelope so iOS-edited timelines survive a round-trip through the web library. No editor pill, no dispatcher — full web parity (UI + playback) lands in v1.2 (logged in ROADMAP `v1.x ideas`). The deferred scope: ~150 lines for a JS `AutomationDispatcher` mirror + ~500 lines for the editor sheet + pill UI. Cache-bust bumped (`main.js?v=45`).

### Documentation

- **Manual.** New §10b documenting the automation feature, the editor flow, and the Journey-vs-Automation distinction.
- **ROADMAP.** Spec under "Shipped" with the five locked design decisions referenced back to commit `4a75462`. Web editor / dispatcher logged under "v1.x ideas (unscheduled)" with an effort estimate.

### Tagged

- `v1.0-build11` (annotated tag, points at `d7ef33c`) marks the App Store launch commit — the safe revert point if v1.1 needs a rollback.
- `web-launch-v1.0` (annotated tag, same commit) marks the live-deployed web state at launch.

---

## v1.0 (build 11) — App Store launch

The actual launch build. Build 10 was withdrawn from App Store review before going live; everything in 10 plus a feature pass on top folds into build 11. Headline addition is the fifth LFO per voice with its own dedicated target set (granular params, delay subdivisions, reverb decay/mix) — bumps the modulator count from 16 to 20 per patch.

### New

- **Fifth LFO per voice.** Same five shapes (sine / triangle / sawtooth / square / S&H), same BPM-syncable rate, but a dedicated nine-target set that none of LFOs 1–4 can reach: **grain size / density / jitter / spread** for stuttering pulse textures and grain-rate accelerandos; **delay time / feedback / mix** for chorus-y shimmer and breathing tail length; **reverb decay / mix** for room-size breathing and independent wet swells. LFO 5 lives in its own row right below LFO 4, with a two-row chip grid grouping the targets (grain on top, FX on the bottom). Older 4-LFO presets continue to load with LFO 5 disabled — no migration step required.
- **20 multi-target modulators per patch** (4 LFOs × 7 shared synth targets + 1 LFO × 9 dedicated FX/granular targets, all across the 4 voices). The headline "Sixteen multi-target LFOs" copy in the App Store listing and the manual is updated accordingly.
- **BPM display + metronome icon lifted into the header.** Both were buried at the bottom of the controls scroll view (below all four oscillator strips). On iPhone landscape with a tall sample-mode strip they were effectively undiscoverable. Now always visible in the top-right icon row next to ?/📸/spectrum/Chladni. Same audio behaviour as before.

### Polish

- **Smoother stop bloom.** The atmospheric reverb-bloom on Stop is gentler — the wet wash drifts in and out (Ken Perlin smootherstep curve, zero first AND second derivatives at the endpoints) instead of sliding, with a lower peak mix (0.30 → 0.20) and a briefer plateau (0.15 → 0.05). The 10 s master fade still carries the overall taper; the bloom inside it now reads more like a slow breath than a swell.

### Bug fixes

- **Pause and Stop fade out audibly again (iOS).** The June 1 "metronome before Play" feature accidentally regressed both Pause and Stop into hard cuts: the voice-silence guard added inside the source-node closure was firing the instant `engine.isAudible = false` (which Pause/Stop flip BEFORE kicking off their fade Tasks), zeroing voice output at the source — so the master fade was attenuating already-silent signal and the reverb bloom had no input to swell. Split the two concerns: the source-node guard now hooks off a separate `voicesMuted` flag that's only set during the metronome-pre-Play preview. Pause = audible 1.4 s exponential fade. Stop = audible 10 s atmospheric stop with full reverb bloom.
- **No click or tail-loss on Pause/Stop when LFO 5 reverb/delay targets are at rest.** The buffer-rate smoothing on the LFO 5 FX mod accumulators was running even when no LFO 5 target was active, leaving residual drift on the smoothed values after any prior LFO 5 activity. During the master fade, that drift was changing `effReverbDecaySec` per buffer, which recomputes the comb-filter feedback coefficients per buffer — exactly the failure mode that the `startStopBloom` comment warned about. The smoothing now hard-snaps to identity when its LFO target is not active that buffer, guaranteeing bit-identical pre-LFO-5 behaviour on the FX path at rest.
- **Click reduction on LFO 5 dTime / dFB / dMix at high depth.** Even before the snap-to-identity fix, the dTime / dFB / dMix targets were clicky at high LFO 5 depth with S&H or square shapes — the per-buffer mod was stepping the gain stages hard. Added a ~50 ms exponential smoothing on the mod accumulators and reduced the swing amounts so steps now roll in gradually rather than instantly.
- **Quantize-to-scale now engages reliably on preset load and on Play.** Was intermittent on the web: when a preset with quantize-to-scale on was loaded, or when transport stopped and played again, the quantize flag could end up off on freshly-rebuilt voices. Now defensively re-pushed on every preset load and on every Play, on both iOS and web.
- **Modal chords now arpeggiate across the full 7-note scale when quantize-to-scale is on.** Was snapping pitch-LFO output to only the 4 chord tones, which clustered S&H steps onto the root. Modal entries (Ionian / Dorian / Phrygian / Lydian / Mixolydian / Aeolian / Locrian + Harmonic & Melodic Minor) now carry their full 7-note mode and quantize uses all 7 degrees.
- **LFO rate sync + grain density sync survive transport stop.** Web only: when Stop wiped the voice list, fresh voices came back without the LFO denomination → rate or grain denomination → density bindings that had been pushed when the preset loaded. Both now re-applied on every Play.

### Presets (since build 9)

- **JG Maybe Three** (Developer Patches) — quiet hybrid pad with all four voices feeding the chorus mix, S&H pitch with quantize on the lead, glacial drift on OSC 4.
- **JG Low Intensity** (Developer Patches) — quiet meditative bed: 110 Hz triangle pad + two A3 granular voices + a 159 Hz sawtooth low drone that fades in at 60 s. S&H pitch syncs to 1/16 at preset BPM; quantize-to-scale keeps the steps inside the active mode.

### Under the hood

- iOS Voice.swift LFO arrays expanded from 4 → 5 entries across all six per-voice arrays (shape, targets, rate, depth, phase, hold). New `padLfosTo5(at:)` helper in `DroneViewModel` re-pads loaded presets so the iOS LFO setters can't no-op on a 4-element array.
- Web `audio.js` mirrored: `for (let k = 0; k < 5; k++)` loop, nine target string handlers matching iOS raw values, `_padLfos(v)` helper, and a Promise-clean handler for the three iOS-only chips (no-op on web, present in the schema).
- LFO 5 row UI: extracted `lfoTargetChip` helper in `OscillatorStrip.swift` and switched to a two-row `VStack` chip layout (grain on top, FX on the bottom) so iPhone landscape doesn't squeeze the nine chips off-screen.
- **gen_swift automation** — the JG-preset generator now emits both the Swift preset block (for `Preset.swift`) and the web JS entry (for `music.js`) in one pass, including LFO configs and drift configs.
- **RecordingSetup.md** — screen-recording workflow doc capturing what works for App Store previews (physical iPhone + QuickTime) and what doesn't (iOS Simulator audio is silently dropped by both `simctl recordVideo` and ScreenCaptureKit).

---

## v1.0 (build 9) — earlier feature-complete TestFlight pass

The public v1.0 release. Build 9 is the App Store launch build, consolidating everything from the previous TestFlight history (1.0 builds 1–6 → relabeled 1.1 builds 7–8 → folded back to 1.0 build 9 for launch) plus the final feature pass below.

### Synth architecture

- Four oscillator voices, each with its own signal chain: waveform (sine / triangle / sawtooth / square / white-noise / pink-noise / granular-pink / loaded sample), state-variable filter (LP / HP / BP), drive (tanh saturation), four LFOs, FM, stereo chorus, mono / stereo / ping-pong delay, stereo Schroeder reverb.
- **Multi-target LFOs**: each LFO can drive pan + amplitude + cutoff + Q + pitch + FM-index + the new **FX-Mix macro** simultaneously. Sixteen multi-target modulators per patch.
- **FX-Mix LFO target** — a single LFO biases the voice's reverb, delay, and chorus wet mix together (±0.5 around the base values), producing one coordinated wet/dry breathing swell across the entire effects rack instead of riding three sliders. Great for dub-style "let it ring out, pull it back" gestures.
- **Quantize to scale** — per-voice toggle in the 🌀 drift menu that snaps the post-modulation pitch to chord notes (~2 octaves around base). Continuous drift becomes mode-correct arpeggios.
- **Modal chord templates** — Modal category in the chord picker with 9 entries: Ionian, Dorian, Phrygian, Lydian, Mixolydian, Aeolian, Locrian, Harmonic Minor, Melodic Minor. Each captures the mode's four most identifying degrees. Quantize-to-scale snaps to those notes so pitch LFOs arpeggiate *inside the mode* instead of wandering chromatically.
- **80+ curated presets** in seven categories — INIT (a neutral starting patch, pinned top), Drone Artists (48 tributes incl. (Granular) and (Fading) variants, plus a Drift Showcase set), Developer Patches (16 patches built around granular sampling + BPM-locked grain + FX-Mix LFO), Solfeggio, Natural Resonance, Cymatics, Mystic & Composers.

### Granular — noise and samples, BPM-locked

- **Granular waveform** — pink noise chopped into Hann-windowed grains with controls for size (5–500 ms), density (0.5–50/s), timing jitter, and stereo spread.
- **Granular sampling** — Sample-waveform voices gain a **GRAINY** toggle. When on, continuous playback is replaced by a Hann-windowed grain scheduler that reads slices around a user-set position (`pos`) with a per-grain offset jitter (`scan`). Same grain controls as the noise scheduler. Frozen Tibetan bowls shimmering forever, Basinski-style tape-decay clouds from any source, vowel sustains held without rhythm. Web + iOS.
- **BPM-quantized grain density** — a denomination chip next to the DENSITY slider cycles through musical subdivisions (½ → 1/32T) of the global BPM. Once quantized, the density follows tempo automatically — change BPM and every quantized voice retimes instantly. Polyrhythmic textures from a single sample.
- **Granular CPU optimization** — per-sample `cos` replaced by a 1024-entry Hann LUT; `Double.random` replaced by per-voice xorshift64* PRNG. ~10× faster grain windowing, ~20× faster RNG.

### Tunings

- 12-TET, just intonation, Pythagorean, Verdi (432 Hz), Lou Harrison Free JI, Wendy Carlos α/β/γ, Harry Partch 43-tone. Every chord template snaps to the active tuning.

### Per-voice mic capture and tuning

- **Per-voice Tune to Room (👂)** — every oscillator strip has an ear icon that opens a YIN pitch-detection sheet scoped to *just that voice*. Sing or play a tone; tap "Set as Freq" and only the strip you tapped snaps. Independent of the global LISTEN pill (which retunes the chord root). Stack across strips to sing a chord into the synth one voice at a time.
- **Per-voice Record sample (🎙)** — captures mic audio directly into a voice's sample slot. Normalized to consistent loudness, saved into the "Recorded Samples" group of the Bundled ▾ picker for reuse elsewhere, and loaded into the voice with the WINDOW row revealed for trim+fade. The voice's frequency at record-time becomes the sample's reference pitch — resampling later matches what you played.
- **Global Tune to Room (LISTEN pill)** — YIN pitch detection from the mic, snap the chord generator's *root* to whatever you sing or play. The last detected pitch is held on screen so you don't race the readout.

### Cross-device preset sharing — `.dronepreset` files

- **Share a saved preset** — every entry in **Your Presets** has a Share button that packs the preset (plus any audio sample it references) into a single `.dronepreset` JSON envelope and opens the iOS share sheet: AirDrop / Save to Files / Mail / Messages / iCloud Drive. Sample audio rides inline as 16-bit WAV so it's platform-universal.
- **Import a preset** — top-right toolbar button in the Presets sheet opens a Files picker filtered to `.dronepreset` (plus `.json` fallback). Imported presets get a fresh id so importing the same file twice creates two distinct entries.
- **Tap-to-open** — a `.dronepreset` shared via AirDrop / opened in Files / tapped in Mail hands directly to Drone Meditations and imports automatically. Custom `com.gude2000.dronemeditations.preset` UTI registered in Info.plist.
- **Same on web** — share-as-download + import-from-file mirrored in the browser app. iPhone → iPad → web round-trip preserves identical audio (including granular state + window + drift).
- **iCloud auto-sync** — saved presets (without inline samples) sync between your iPhone and iPad automatically via NSUbiquitousKeyValueStore. Samples still travel via `.dronepreset` files.
- **Existing local samples never clobbered** — incoming preset references that name a sample you already have on disk leave the local file untouched.

### Timing — per-voice envelopes + global BPM

- **Per-voice timing envelope** — every voice gets *Start after* (Now / 15 s / 30 s / 1 / 2 / 5 / 10 min) and *Play duration* (Forever / 1 / 3 / 5 / 10 / 15 / 20 min) chips. Voices fade in over 8 s and fade out over 10 s at each boundary. Several Drone Artists presets use this to bloom voices in at different times.
- **Replay × N** — a third chip row sets each voice's [silent delay → fade-in → audible → fade-out] cycle to repeat Once / × 2 / × 3 / × 5 / × 10 / ∞. Subsequent cycles use a 4 s fade-in (vs. 8 s on the first) and a per-cycle reverb-bloom fade-out so each repetition dissolves into the room before the next one starts.
- **Global BPM + delay sync** — a tempo field drives every voice's delay-time when that voice's timing is set to a musical division (½, ¼, ¼t, ⅛, ⅛t, 1/16, 1/16t). Default 80 BPM (resting-heart-rate territory, meditative without being sluggish), range 30–240. iOS picker in the master row; web exposes it via tap-the-subtitle. Same BPM also drives BPM-quantized grain density.

### Cymatics

- Physically-calibrated Chladni-plate renderer, fit from 17 frames of brusspup demo footage: `f(m,n) ≈ 18.6·(m²+n²)`. The renderer crossfades between the two adjacent eigenmodes that bracket each voice's live pitch — so vibrato breathes between physical modes, not stylized animation.
- **Sand particles in Perform** — fullscreen Performance mode now includes a drifting sand-particle simulation (~3000 on web, ~1500 on iOS) that rides the cymatic gradient toward nodal lines. Grains physically migrate when frequency changes. Available on both web and iOS, on top of the same simulation that already ran in the web pop-out.
- Pop-out window (web) + fullscreen Perform mode for installations. Pinch / scroll zoom. Performance exit pill never disappears (dims to 45 % after 3 s, taps anywhere wake it).
- **Chladni CPU optimization** — 4 per-mode cos arrays of size `grid` precomputed once per frame; inner cell loop becomes 4 array reads + 2 multiplies + 1 subtract. ~140× fewer `cos` calls per frame (~15M/s → ~107k/s).

### Visualizers

- Cymatic (default) and Spectrum (FFT bars) — toggle via header icons.

### Meditation Journeys

- 25 scripted multi-stage sessions that auto-advance presets + drift over a fixed duration: 15 general (Sundown, Awakening, Floating, Body Scan, Cathedral, Mountain Climb, Vespers, Crystal Cave, Phi Spiral, Quartz, Lullaby, Tibetan Bowl, Storm Front, Centering, Spiral Descent) + 10 Drone Artist arcs (Deep Listening Lineage, Heavy Resonance, Minimalist Arc, Spiritual Path, Sonic Cathedral, Black Mass, Slow Bloom, Tape & Tar, Awakening Drone, Microtonal Garden). Each fades gently at the end. Compose your own from the "＋ Create your own journey" button.

### Drift

- Per-voice slow generative motion. Pitch modes: Static / Up / Down / Up-Down / Down-Up / Wave / Ocean (±¼-semi / 90 s) / Glacial. Pan modes parallel. Amount + Period overrides per voice (so a 20-min glacial bass can sit under a 30-s wave on a pad).
- Quantize-to-scale toggle (described above) makes drift step through chord notes instead of smearing chromatically.

### Morph

- Pick two presets, drag the slider to crossfade between them — every per-voice parameter interpolates (log on frequencies / filter / decay / delay / chorus rate / FM index; linear on mix / depth / pan / drive / feedback / width; discrete swap at midpoint on waveform / filter type / delay mode / FM source / LFO shape + target). Auto-morph timer: 30 s to 60 min, optional ping-pong loop.

### Recording

- Master output → **24-bit WAV** (DAW-ready, bit-perfect) **+ AAC M4A sidecar** (~10× smaller for sharing). Both files mastered with -16 dBFS RMS gain + 2 s fade-in / 4 s fade-out + metadata, saved to `Drone Meditations/Recordings/` in the Files app.

### Stereo reverb + audio-thread CPU optimization

- **Stereo reverb** — the Schroeder JCRev now runs two independent chains (L + R) with slightly different comb and allpass lengths so the wet tail decorrelates naturally. The chorus's already-stereo output feeds the L/R chains directly. Hard-panned voices still spread their reverb tail across both channels.
- **Bypass guards** — per-sample reverb / delay math is skipped when the relevant mix is at 0, saving ~9M ops/sec on a typical preset.
- **Per-sample slew** on every gain-stage slider (reverb mix, delay mix, delay feedback, chorus mix, delay time, chorus depth, drive, FM index) — kills the audible crackle on parameter drags. Time constants tuned to balance smoothness with responsiveness.
- **Per-voice ObservableObject** — each `OscillatorStrip` subscribes to its own `OscillatorVoice` box instead of the global view-model. Slider drag on OSC 1 no longer triggers `body` recomputation on OSC 2/3/4 — ~4× less SwiftUI work per frame on a four-voice patch.
- **Computed `oscillators` property** — the VM's `@Published var oscillators` is now derived from voiceBoxes, so writes don't fire the VM's own `objectWillChange`. Eliminates the body-recomputation storm that was spiking past the audio buffer deadline.
- **LFO → filter mod** — per-sample slew with 15-ms time constant + biquad coefficients recomputed every 16 samples. Eliminates the click on square / S&H / ramp LFO shapes targeting cutoff or Q.

### Web app parity

Every feature above runs on the web app (dronemeditations.com) too, including: per-osc Tune + Record icons, granular sampling, BPM-quantized grain density, FX-Mix LFO target, modal chord templates, multi-target LFOs, drift quantize-to-scale, Replay × N, .dronepreset share/import, sand particles in Perform, and all 80+ presets. Web-specific extras: pop-out Chladni window with BroadcastChannel sync, scroll-wheel Chladni zoom, Web MIDI input.

### Polish & first-launch experience

- Click-free pause and stop with atmospheric reverb-bloom fades — 8 s logarithmic on Stop, 1.4 s gentle "lift then settle" on Pause. Each voice's wet mix + decay bloom upward then descend back as the master fades, so the sound dissolves into the room rather than disappearing.
- 5-card first-launch onboarding tour (re-openable from the ? button).
- Per-voice ⭐ preset library + per-voice 🎲 randomize.
- Global 🎲 Randomize-all + ↶ Undo at the end of the OSC pill row.
- Sample play-window (start / end / fade-in / fade-out) for trim + per-loop fades.
- iPad single-row transport with 56-pt play button.
- Haptics intensity (iOS) — Off / Light / Heavy cycle, persisted across launches.
- Auto-play start when selecting a new preset is gated behind the `isAudible` engine flag — selecting a preset never triggers playback, and Stop is always tappable.

### Privacy

- Zero data collection. No accounts. No network. No analytics. Microphone is processed live for Tune to Room and per-voice Record only; recorded audio stays on-device unless you explicitly share a `.dronepreset` containing it.

---

## v1.1 — planned post-launch

Features not in v1.0 build 9; first candidates for v1.1:

- **LFO rate sync** — per-LFO `Sync` toggle that locks rate to a BPM division (½, ¼, ⅛…). Useful but unproven need for a drone synth; revisit if users ask.
- **Native sample library expansion** — more bundled samples, especially long-form field recordings and vocal sustains for the sampler.
- **Additional Drone Artists presets** — community-suggested tributes.

Anything beyond is open. Reviewer feedback will shape the v1.1 backlog.
