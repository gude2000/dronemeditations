# Reviewer / YouTuber outreach email — Drone Meditations

Send-ready template covering the full v1 feature set: granular
sampling, BPM-quantized grain density, FX-Mix macro LFO, per-voice
Tune-to-Room and mic Record, cross-device preset sharing, and the
per-voice timing envelope with Developer Patches. Customize the
bracketed bits per recipient.

---

## Short version (cold DM / Twitter / Instagram)

> Built a 4-voice drone synth + Chladni cymatics for iOS / web —
> samples chop into Hann-windowed grains that can lock to musical
> subdivisions of the global BPM, a single LFO target sweeps
> reverb+delay+chorus mix together for breathing wet/dry swells,
> every strip has its own ear/mic icons (tune-to-room and direct-to-voice
> record), presets cross-device via AirDrop, voices fade in/out on
> a per-voice timing envelope so a patch rotates harmonically over
> 20 minutes without touching a slider. Free for press, want a
> TestFlight invite?
>
> dronemeditations.com/press

---

## Long version (email, 250-450 words)

**Subject:** Drone Meditations v1 — granular + BPM-locked grain density,
per-voice tune & mic record, cross-device presets on iOS

Hi [name],

I'm a solo dev shipping a four-voice drone / meditation synthesizer
called Drone Meditations. It's been in TestFlight long enough that
you've probably caught one of [previous reference if applicable] — I
wanted to send a fresh look because v1 added a cluster of features I'd
love your ears on.

**Granular sampling, now BPM-locked.** Sixty-plus bundled samples —
bansuri, organ, piano sustains, recorded environments (storm, tide,
forest, urban ambiences), cosmic textures — can each be sliced into
Hann-windowed grains with adjustable size, density, jitter, pan
spread, plus position and scan. New in this build: grain density
optionally locks to a musical subdivision of the global BPM (½ →
1/32T), turning any sustained sample into a tempo-locked rhythmic
instrument while keeping its harmonic content intact. Position scan
+ jitter let you freeze a single harmonic moment of a file forever,
or smear a Scriabin mystic chord into a Basinski-style tape-decay
cloud — now with the option to make it a polyrhythmic cloud instead.

**Per-voice mic capture and tuning.** Each oscillator strip has its
own ear icon (Tune to Room — YIN pitch detection that snaps just
that voice to a sung or played pitch) and mic icon (Record sample
— captures audio straight into the voice's sample slot, normalized
and granular-ready, with the voice's frequency at record-time as
the reference pitch). Sing a chord into the synth voice-by-voice,
or capture a singing bowl through your phone and immediately
granularize it. No Files-app round-trip, no upload step.

**FX-Mix macro LFO.** A new "FX" target lets a single LFO bias
reverb, delay, and chorus mix together as one coordinated wet/dry
breathing. Pair a slow sine-on-FX with the per-voice timing
envelope and you get dub-style "let it ring out, pull it back"
gestures from one modulator instead of riding three sliders.

**Cross-device preset sharing.** Any preset (including its samples)
exports as a single `.dronepreset` file. AirDrop from web → iPhone
→ iPad and the same patch lands on each device — sample audio
embedded as 16-bit WAV inside the envelope so it's universal, not
platform-locked.

**Per-voice timing envelope.** Each voice can have its own start
delay, play duration, and Replay × N (or ∞). Voices fade in over
8 s (4 s on subsequent cycles) and fade out over 10 s at each
play-duration boundary, so a four-voice patch can rotate
harmonically across a 20-minute session without a single slider
touch. It changes what a "drone preset" can be.

I'd love to send you a TestFlight invite or a working web link. The
press kit at **dronemeditations.com/press** has high-res screenshots,
pull-quotes, the developer story, and a fresh **Developer Patches**
category (JG-prefixed) that leans on BPM-quantized grains + FX-Mix
LFO swells — good starting points for a demo if you're recording.
There's also an **INIT** preset pinned at the top of every list if
you'd rather build from a blank canvas on camera.

Happy to answer anything, screenshot a feature, or jump on a call.

Thanks for considering it,
Jose Gude
gude2000@gmail.com
dronemeditations.com

---

## Variation hooks (pick one to tailor per recipient)

- **Modular / Eurorack reviewers** (Richard Devine, Lightbath, mylarmelodies):
  lead with "BPM-quantized grain density on any sample, sixteen
  multi-target LFOs across four voices, one of which can be the new
  FX-Mix macro — rare even in desktop synths"; mention the FM matrix
  + per-voice timing envelope as something not typical in tablet apps.

- **Ambient / meditation channels** (Mind & Body, Silentmind):
  lead with the meditation journeys + ocean drift + 20-minute
  hands-free sessions + 1500-particle Chladni sand in fullscreen
  Perform mode; downplay the technical end.

- **Sound design / educators** (Andrew Huang, Benn Jordan):
  lead with the Chladni-plate visualizer fit to brusspup demo
  footage + the granular sampling + the BPM-quantized grain density
  as a teaching example for how musical timing meets micro-sound;
  pitch as "instrument for thinking about overtones".

- **Drone artists in tribute presets** (any of Oliveros, Riley
  estate / heir, Hassell estate / heir, Niblock, Palestine, Wada,
  Budd estate, etc. if reachable): lead with the tribute — "your
  signature sound is preset 3 of our Drone Artists category" — and
  ask if they'd like a TestFlight to hear it on their own device.

---

## Pull quotes (lifted from press.html, reusable)

> "One LFO can drive pan, cutoff, pitch, Q, FM, amplitude, or the new
> FX-Mix macro — and it can drive several at once. Sixteen multi-target
> modulators across four voices. Rare even in desktop synths."

> "Hold a singing bowl up to your phone. Tune to Room hears it and
> snaps the chord generator — or just a single voice — to its exact
> frequency. The drone never beats against your acoustic source."

> "The cymatic visualizer is fit from 17 frames of brusspup demo
> footage. Vibrato breathes between physical eigenmodes of an actual
> thin square plate."

> **NEW v1:** "A bansuri sustain chopped into 220 ms Hann grains, then
> retimed to 1/8t of the song's BPM, doesn't sound like a bansuri
> anymore. It sounds like the room remembering one — on the beat."

> **NEW v1:** "One LFO on the new FX target swings reverb, delay, and
> chorus mix together. Wet/dry stops being a slider and starts being
> a gesture."

---

## Press kit links

- Hub: **dronemeditations.com/press**
- App Store: [insert App Store link when live]
- TestFlight: [private link per recipient]
- Demo video: [insert demo video link if recorded]
- Direct contact: gude2000@gmail.com
