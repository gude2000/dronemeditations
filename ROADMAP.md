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

### v1.1 — Automation Timeline (iOS) ✅ Phase A + B + C complete

Per-patch time-based event automation. iOS feature, behind the new
`AUTOMATION` pill in the top control row (right after PRESET).
Six event types: chord change, fade in, fade out, waveform set,
level set, mute toggle. Per-event `Voice` filter (All / OSC 1-4)
applies events to a specific voice or the whole patch. Duration
defaults to "manual stop" (0); set a positive duration with the
Loop toggle for looping timelines. Persisted in `.dronepreset` as
an optional `automation` field — older saves load with an empty
timeline; web app preserves the field on round-trip (no editor on
web in v1.1 — Phase D / v1.2).

Spec frozen in commit `4a75462`. Built across three phases:
Phase A (`98673b6` — data model + dispatcher + sheet UI + chord
+ fade events + persistence), Phase B (waveform / level / mute
event types), Phase C (loop wrap, web schema round-trip, manual
update, CHANGELOG entry).

Tasks #205, #206, #207. See `CHANGELOG.md` v1.1 entry for the full
notes.

---

## v1.1 — Automation Timeline (in design)

Time-based event automation that modifies a single preset over its
playback. Lets a user script chord changes, fades, waveform switches,
and per-voice level/mute events at specific time markers within a
patch. Complements (does not replace) Journey mode.

### Design decisions (locked)

1. **Pill location** — Insert `AUTOMATION` right after `PRESET` in
   the top pill row: `CHORD · PRESET · AUTOMATION · DRIFT · LISTEN ·
   PERFORM · JOURNEY · MORPH · GALLERY`. Pill shows event count when
   non-empty (`AUTOMATION · 6 events`).
2. **Default duration** — `0 = manual stop`. Timeline is a series of
   one-shot events with no forced patch duration. User opts into
   duration only if they want loop behavior.
3. **Voice filter semantics** — `Voice: All` events affect all four
   voices **regardless** of whether the voice has been faded-in or
   muted by an earlier event. Predictable rule: if a voice doesn't
   exist yet at event time, the action still queues for it when it
   does.
4. **Fade-event precedence** — Timeline `fadeIn`/`fadeOut` events
   **override** the existing per-voice timing envelopes (#83 in
   tasks). If both are present, the timeline wins. Simpler mental
   model and avoids "which fade is running right now?" confusion.
5. **Journey vs Automation** — No mutual exclusivity, no warnings.
   Documented distinction in the manual:
   - **Journey** = scripted multi-*preset* sequence (changes the
     whole patch at each stage).
   - **Automation** = within-preset event timeline (modifies the
     current patch over time).

### Data model

```swift
struct AutomationEvent: Codable, Identifiable {
    let id: UUID
    var timeSec: Double      // when (0…totalDurationSec)
    var voice: VoiceFilter   // who
    var action: Action       // what
}

enum VoiceFilter: Codable {
    case all
    case oscillator(Int)     // 0…3
}

enum Action: Codable {
    case chordChange(key: PitchClass, template: ChordTemplate)
    case fadeIn(durationSec: Double)         // 0…15
    case fadeOut(durationSec: Double)        // 0…15
    case waveformSet(Waveform)               // discrete; no morphing in v1.1
    case levelSet(Float)                     // 0…1
    case muteToggle
}

struct AutomationTimeline: Codable {
    var totalDurationSec: Double = 0  // 0 = until manual stop
    var loop: Bool = false
    var events: [AutomationEvent]     // dispatcher sorts by timeSec
}
```

### Engine integration

`AutomationDispatcher` runs on the main actor, polls
`engine.transportElapsed` at ~30 Hz (CADisplayLink or Timer). Tracks
`nextEventIndex`. When elapsed crosses
`events[nextEventIndex].timeSec`, fires the event via the existing
setters (`vm.setChord`, `vm.setWaveform(for:)`, etc.), then advances.

- **Play** → reset index + elapsed, dispatcher starts polling
- **Pause** → dispatcher pauses (time freezes)
- **Stop** → reset index + elapsed
- **Loop on, end of duration** → reset index + elapsed, continue

DSP untouched. Automation just calls the same setters the UI uses.

### File format

`.dronepreset` gets one optional `automation` field. Older presets
without it load with an empty timeline (same pad-on-load pattern
used for LFO 5). Additive change — no schema version bump.

```json
{
  "voices": [...],
  "chord": {...},
  "automation": {
    "v": 1,
    "totalDurationSec": 0,
    "loop": false,
    "events": [
      {"id":"…","t":0,  "voice":"all", "a":{"type":"chord","key":"A","template":"minor7"}},
      {"id":"…","t":150,"voice":"osc0","a":{"type":"fadeIn","durationSec":3}},
      {"id":"…","t":300,"voice":"all", "a":{"type":"chord","key":"D","template":"dorian"}}
    ]
  }
}
```

### UI

- **Top pill** — `AUTOMATION` between PRESET and DRIFT
- **Tap pill** → opens automation sheet listing all events in time
  order, with Duration + Loop controls at the top, `+` to add
- **Tap an event** → opens event editor sheet (time, voice filter,
  action type + action-specific fields)
- **Swipe left on event row** → delete
- **No new icon on the per-voice strip** — per-voice automation is
  accessed via the Voice dropdown inside the patch-level editor

### Phased build

| Phase | Scope | Est. effort |
|---|---|---|
| **A: Foundation** | Data model + AutomationDispatcher + sheet UI listing events + chord-change events + fade events + persist in `.dronepreset` | 2–3 weekends |
| **B: More event types** | `waveformSet`, `levelSet`, `muteToggle` | 1 weekend |
| **C: Polish + web parity** | Loop support, web `audio.js` mirror, manual update, CHANGELOG entry, transport mini-indicators (optional) | 1 weekend |

Ship A+B+C together as v1.1.

### Explicitly NOT in v1.1

- Waveform **morphing** (sine → square smooth crossfade). Discrete
  `waveformSet` events only. Morphing requires a wavetable engine —
  v2.0 project.
- Curve types between events (linear, ease-in-out, exponential).
  v1.1 = step changes. Curves = v1.2.
- Multiple actions per event row. One event = one action. If you
  want three things at 5:00, create three events at 5:00.
- BPM-change events.
- Drift-mode-change events.
- Conditional logic.

### Risks

- **Schema sprawl.** Soft cap 50 events per timeline, hard cap 200.
  Show UI warning past 50.
- **Pause edge case.** Pause must freeze the dispatcher; events
  during a paused window do not fire. Dispatcher polls
  `transportElapsed`, not wall-clock.
- **Save/Load testing surface.** Round-trip preset iOS → web → iOS
  to verify timeline integrity. Add to pre-submission checklist.

---

## v1.x ideas (unscheduled)

- **Automation Timeline — web editor + dispatcher.** v1.1 ships
  automation as iOS-only at the edit/playback level. The web app
  preserves the `automation` field in the `.dronepreset` envelope
  on round-trip (iOS-edited timelines survive a save-on-web →
  share-back-to-iOS cycle), but doesn't surface an editor pill or
  dispatch events at play time. v1.2 should mirror the iOS
  `AutomationDispatcher` in JS (≈150 lines) and add an Automation
  pill + sheet + event editor to the web UI (≈500 lines).
- **LFO 5 sample-granular targets** — Position, Scan range, and per-
  voice Overlap on/off as additional LFO 5 chips (originally part of
  the v1.1 plan, deferred). Would unlock scanning-over-time textures
  and rhythmic grain-overlap gating.
