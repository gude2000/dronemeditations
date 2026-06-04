# Drone Meditations — Screen Recording Setup Notes

Collected findings from a long debugging session trying to produce the
App Store preview video on macOS. Pairs with `AppPreviewStoryboard.md`,
which is the *what* (cut list, timing, on-screen text); this doc is the
*how* (which tools, which dead-ends, which gotchas).

**Bottom line up front:** the path that actually delivers an
App-Store-ready preview is **a physical iPhone + QuickTime Player on
the Mac**. Skip straight to that section if you just want to record now.

---

## Deliverables

Three distinct recordings get confused for each other — they have
different format requirements:

| Deliverable | Aspect | Resolution | Audio | Where it goes |
|---|---|---|---|---|
| **App Store iPhone preview** | Portrait | 1080×1920 (or 886×1920) | Required | App Store Connect → 1.0 → App Previews & Screenshots |
| **App Store iPad preview** | Landscape *or* portrait | 1600×1200 / 1200×1600 | Required | Same form, iPad slot |
| **Landing page hero / press / social** | Landscape | 1920×1080 | Required | dronemeditations.com, press kit, social |

The storyboard in `AppPreviewStoryboard.md` is written for the
**iPhone preview** — portrait, iOS app.

---

## Route 1 (recommended): Physical iPhone + QuickTime

For App Store iPhone preview. Cleanest path. ~30 min to a final file.

1. Connect iPhone (recent model, ideally iPhone 17 Pro Max to match the
   simulator targeting) to the Mac via USB-C cable
2. Trust the computer on the iPhone if prompted
3. Open **QuickTime Player** → File → New Movie Recording
4. Click the dropdown ▾ next to the record button
   - **Camera:** the connected iPhone
   - **Microphone:** the connected iPhone (this is the trick — uses the
     iPhone's *audio output*, not its mic)
   - **Quality:** Maximum
5. The iPhone screen mirrors into QuickTime. Set it to portrait by
   rotating the iPhone — QuickTime auto-rotates to match
6. Open Drone Meditations on the iPhone, get it to the storyboard
   starting state (Performance fullscreen cymatics, drone playing)
7. Hit record in QuickTime, drive through the storyboard, hit stop
8. File → Export As → 1080p → save as `preview-take-N.mov`
9. Edit in iMovie or Final Cut Pro per the storyboard cut list

Audio is captured directly from the iPhone's audio output — no routing
tricks needed, no BlackHole, no Multi-Output Device.

---

## Route 2: Web app (landscape) for landing-page / press / social

This is what was set up during the debugging session. Works for
non–App-Store deliverables.

### One-time setup

1. Install BlackHole 2ch: `brew install blackhole-2ch`, **reboot**
2. Open Audio MIDI Setup → create Multi-Output Device, check
   `BlackHole 2ch` + your real output device (`Universal Audio
   Thunderbolt` for this Mac)
3. `System Settings → Sound → Output → Multi-Output Device` as default
4. Install OBS: `brew install --cask obs`
5. Grant OBS Screen Recording in `System Settings → Privacy & Security
   → Screen & System Audio Recording` (without this, OBS source lists
   come up empty — silent failure mode)
6. In OBS:
   - Source → `+` → macOS Screen Capture → method: Display Capture
     (or Window Capture targeting the browser)
   - Audio mixer: mute Mic/Aux. **Use the macOS Screen Capture
     source's built-in audio** — that's ScreenCaptureKit's system audio
     capture and it Just Works for web apps
7. Settings → Output:
   - Mode: Simple
   - Recording Quality: High Quality, Medium File Size
   - Format: Hybrid MP4 (.mp4) — crash-safe, universal
8. Settings → Video: 1920×1080, 60 fps

### Recording

1. Open Drone Meditations in **Chrome** (not Comet — Comet has its
   own per-app audio routing quirks that broke our run; Chrome behaves)
2. Refresh the page so Web Audio binds to the current default output
3. Hit Play in Drone Meditations
4. OBS → Start Recording, drive the storyboard, Stop Recording
5. File lands in `~/Movies/2026-...mp4`

### Verify any take

```bash
# audio level check — silent recordings show -91 dB
ffmpeg -i "$LATEST" -af "volumedetect" -vn -f null /dev/null 2>&1 \
  | grep -E "mean_volume|max_volume"

# stream listing — confirm both audio + video exist
ffprobe -v error -show_streams "$LATEST" | grep codec_type
```

A healthy file shows mean ~−15 dB, max ~−3 dB. A `−91 dB` mean is
digital silence — the encoder wrote zeros.

### Cleanup after recording

Switch System Settings → Sound → Output back to your real device
(Universal Audio Thunderbolt) — otherwise everything else routes
through Multi-Output → BlackHole permanently and you'll wonder why
YouTube sounds quiet later.

---

## Route 3 (proven to fail): iOS Simulator

The simulator route looks attractive (no physical device needed) but
audio is broken in two distinct ways:

| Capture method | Video | Audio | Why |
|---|---|---|---|
| `xcrun simctl io recordVideo` | ✅ | ❌ | Apple's tool is video-only by design — no `--audio` flag exists. Confirmed in `xcrun simctl io --help`. |
| OBS Window Capture of Simulator + ScreenCaptureKit audio | ✅ | ❌ | ScreenCaptureKit's system-audio capture does NOT pick up iOS Simulator audio on macOS. Simulator uses CoreSimulator's own audio path which bypasses the system mix. |

**Possible workaround (untested):** `Simulator → I/O → Audio Output →
BlackHole 2ch`, then add a BlackHole Audio Input source back to OBS.
Theoretically routes the simulator's audio through BlackHole where OBS
can grab it. **We did not test this — abandoned the route in favor of
the physical iPhone path. Try it if you really need the simulator.**

---

## OBS gotchas we hit

These wasted time during setup. Capture for future-you.

- **Empty source dropdowns = missing permission.** OBS Display /
  Window / Application capture all show empty lists if Screen Recording
  permission isn't granted. There's no error message; the dropdowns
  just have nothing in them. Grant it, **quit and relaunch OBS**.
- **Right-click → "Use This Device For Sound Output" is greyed out on
  Multi-Output Devices in recent macOS.** Set the default via System
  Settings → Sound instead.
- **The Audio MIDI Setup app shows BlackHole only AFTER reboot.** The
  brew install message says "must reboot" — easy to skip.
- **OBS audio meter showing signal ≠ recording has audio.** Got bitten
  by this twice. The meter monitors live; the recording uses encoder
  tracks. Both must align. Always verify finished files with
  `ffmpeg volumedetect` before declaring a take good.
- **Comet (Perplexity browser) has its own audio quirks.** Web Audio
  contexts created in Comet stick to the device that was system default
  at AudioContext-creation time, even after the system default changes.
  Refreshing the page rebinds. Easier: just use Chrome for recording.
- **Hybrid MP4 (.mp4) > QuickTime (.mov) for OBS recording.** Hybrid
  format is crash-safe (you don't lose the take if OBS dies). MP4 plays
  everywhere. No reason to use .mov unless your editor demands it.

---

## Apple's App Store preview specs (current as of writing)

| Field | Value |
|---|---|
| Duration | 15–30 seconds |
| iPhone | 1080×1920 portrait (preferred 886×1920) |
| iPad | 1600×1200 landscape or 1200×1600 portrait |
| Frame rate | 30 fps (60 also accepted) |
| Codec | H.264, baseline 3.0+ |
| File size | < 500 MB |
| Audio | Required. Must be present and ducked appropriately. |
| Captions | Optional, recommended for sound-off viewing |

Submit via App Store Connect → Drone Meditations → 1.0 Prepare for
Submission → App Previews and Screenshots → iPhone/iPad slot.

---

## Files left from the debugging session

These can be deleted — none are App-Store-ready:

- `~/Movies/2026-06-04 06-39-13.mp4` — first OBS attempt, silent audio
- `~/Movies/2026-06-04 06-57-17.mp4` — second OBS attempt, silent audio
- `~/Movies/2026-06-04 07-02-01.mp4` — first OBS attempt that worked
  end-to-end (web app, mean −13.2 dB) — keep this one as a known-good
  reference for what a healthy file looks like
- `~/Movies/2026-06-04 07-08-35.mp4` — second working OBS take, audio
  was low (−43 dB) but pipeline confirmed
- `~/Movies/2026-06-04 07-57-24.mp4` — Simulator + OBS window capture,
  silent (the route that exposed ScreenCaptureKit doesn't pick up
  Simulator audio)
- `~/Movies/dronemeditations-preview-take1.mov` — simctl recordVideo
  output, silent by design (345 MB, 3 min of UI walkthrough video only)
