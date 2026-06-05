// Web Audio engine — 4 OscillatorNodes routed through per-voice pan + gain into a master.
// Mirrors the native Voice/AudioEngine architecture.
//
// LFOs are driven from JS via requestAnimationFrame (~60 Hz updates). At sub-audio rates
// (0.02–8 Hz) this is plenty smooth; we write the modulated pan/amp values directly to
// the corresponding AudioParam each frame.

const RAMP_TIME = 0.040;  // 40ms parameter ramps to avoid clicks/zipper noise.
const LFO_SMOOTH = 0.008; // ms-scale ramp on each LFO write — kills DC clicks on S&H steps.

export class AudioEngine {
  constructor() {
    /** @type {AudioContext|null} */
    this.ctx = null;
    /** @type {Array<{osc: OscillatorNode, pan: StereoPannerNode, gain: GainNode, params: object}>} */
    this.voices = [];
    /** @type {GainNode|null} */
    this.master = null;
    this.started = false;
    // v1.1 quantize-to-scale cache. Populated by main.js's
    // recomputeQuantizeScale() whenever chord/tuning/key/octave
    // changes. Read in the LFO/pitch dispatch when a voice has
    // pitchQuantizeToScale = true.
    this.scaleNotesHz = [];

    // The user-visible volume target (0..1). Applied after solo/mute logic resolves.
    // Default 0.30 — with 4 voices + reverb/delay wet sends, anything higher
    // can push the limiter and audibly compress.
    this.masterTarget = 0.30;

    this._rafId = null;
    this._lastTickTime = 0;

    // Transport elapsed seconds, pushed in from main.js on every transport
    // tick. Used by the per-voice timing envelope to know when each voice
    // should fade in (after startDelaySec) and fade out (after
    // playDurationSec, if non-zero). NaN means "not playing" — the engine
    // forces every voice's envelope back to its idle value.
    this.transportElapsed = NaN;
  }

  /**
   * Lazily create the AudioContext. Must be called inside a user gesture handler
   * (click/tap) — browsers won't let us start audio otherwise.
   */
  ensureStarted(initialVoiceState) {
    if (this.ctx) {
      if (this.ctx.state === "suspended") this.ctx.resume();
      return;
    }

    const AC = window.AudioContext || window.webkitAudioContext;
    this.ctx = new AC({ latencyHint: "interactive" });
    // Some browsers create the ctx in "suspended" state until a
    // user gesture explicitly resumes it. ensureStarted() is always
    // called from a user-gesture-driven action (Play tap or
    // metronome toggle), so resume() here will succeed. Without
    // this, a fresh ctx stays suspended and the metronome's first
    // scheduled click never renders.
    if (this.ctx.state === "suspended") {
      this.ctx.resume().catch(() => {});
    }

    this.master = this.ctx.createGain();
    // Start silent; fade-in handled by ensureStartedWithFade below so play
    // begins gently instead of cutting in at full volume.
    this.master.gain.value = 0;

    // Brickwall-ish limiter at -0.1 dB so peaks never clip the destination.
    // High ratio + tiny knee + fast attack approximates a true limiter.
    this.limiter = this.ctx.createDynamicsCompressor();
    this.limiter.threshold.value = -0.1;
    this.limiter.knee.value = 0;
    this.limiter.ratio.value = 20;
    this.limiter.attack.value = 0.001;
    this.limiter.release.value = 0.05;

    this.master.connect(this.limiter);
    this.limiter.connect(this.ctx.destination);

    // Metronome — a dedicated bus that taps the destination *bypassing*
    // master volume, so the click stays audible at a steady level even
    // when the user drops master to silence. Clicks are short sine
    // pings (1500 Hz accent on beat 1, 1000 Hz on 2/3/4) scheduled
    // sample-accurate from the current BPM. See _metronomeTick.
    this.metronome = {
      enabled: false,
      bpm: 80,
      bus: this.ctx.createGain(),
      // Volume kept moderate so it doesn't drown the synth; users
      // toggle on for verification, not for performance.
      level: 0.35,
      nextBeatTime: 0,
      beatCounter: 0,        // 0..3, accent on 0
      timer: null,
      lookahead: 0.12,       // schedule ~120 ms ahead
      tickIntervalMs: 25     // wake every 25 ms to schedule new beats
    };
    this.metronome.bus.gain.value = this.metronome.level;
    this.metronome.bus.connect(this.ctx.destination);

    // Spectrum-analysis tap — AnalyserNode reads the post-limiter signal.
    // Visualizations.js polls getByteFrequencyData() to draw the bars.
    this.spectrumAnalyser = this.ctx.createAnalyser();
    this.spectrumAnalyser.fftSize = 2048;
    this.spectrumAnalyser.smoothingTimeConstant = 0.78;
    this.limiter.connect(this.spectrumAnalyser);

    // Recording tap — same signal that hits the speakers also flows into a
    // MediaStreamAudioDestinationNode so MediaRecorder can capture sessions
    // to a downloadable WebM/Opus file. Created lazily on first recording.
    this.recordDest = null;
    this.mediaRecorder = null;
    this.recordChunks = [];

    for (let i = 0; i < 4; i++) {
      const v = initialVoiceState[i];
      // Synth oscillator + its gain (selectable waveforms sine/tri/saw/sq).
      const osc = this.ctx.createOscillator();
      const oscGain = this.ctx.createGain();
      // Sample bus — node created when a sample is loaded for this voice.
      // v1: sampleContGain is an extra gain stage that ONLY the continuous
      // sampleSrc routes through; grain bursts skip it and feed sampleGain
      // directly. setSampleGranular(true) zeroes sampleContGain so the
      // continuous loop is silenced while the grain scheduler is running.
      // (Setting AudioBufferSourceNode.playbackRate to 0 does NOT silence
      // it — output freezes on the last frame instead.)
      const sampleGain = this.ctx.createGain();
      const sampleContGain = this.ctx.createGain();
      sampleContGain.gain.value = 1;
      sampleContGain.connect(sampleGain);
      // Noise bus — a looping AudioBufferSourceNode fed by either the
      // engine's shared white-noise or pink-noise buffer. We swap which
      // buffer it points to when the waveform changes between the two,
      // and crossfade the noiseGain against oscGain/sampleGain so the
      // active source has the only audible level.
      const noiseGain = this.ctx.createGain();
      noiseGain.gain.value = 0;
      const noiseSrc = this.ctx.createBufferSource();
      // Granular mode reuses pink noise as its source — warmer / more
      // meditation-friendly than white. White/pink modes pick their own.
      noiseSrc.buffer = (v.waveform === "pinkNoise" || v.waveform === "granular")
        ? this._pinkNoiseBuffer()
        : this._whiteNoiseBuffer();
      noiseSrc.loop = true;
      // Per-grain pan offset. Always in the noise signal path — when not in
      // granular mode it sits at 0 (center, no effect). The grain scheduler
      // updates this around the voice's base pan with random offsets.
      const grainPan = this.ctx.createStereoPanner();
      grainPan.pan.value = 0;
      // FM modulation input gain — other voices' raw oscillators get routed
      // through this voice's `fmInput` (with their depth gain), and `fmInput`
      // is connected to `osc.frequency`. Allows cross-voice FM. Default 1.0.
      const fmInput = this.ctx.createGain();
      fmInput.gain.value = 1.0;
      fmInput.connect(osc.frequency);
      const filter = this.ctx.createBiquadFilter();
      // Reverb (ConvolverNode + wet-gain) and Delay.
      //
      // Delay supports three modes (mono / stereo / ping-pong) via two
      // DelayNodes plus four routing-gain nodes that enable or silence
      // the various feedback edges. Wet is sent through a ChannelMerger
      // so we have proper L/R stereo separation independent of the dry
      // path's StereoPanner.
      // Stereo chorus — two short delay lines (delayChL/R) modulated by two
      // sinusoidal LFOs (chLfoL/R) whose phases are offset by `width × π`.
      // Wet path passes through a ChannelMerger to keep L/R independent; the
      // dry/wet balance is set by chDry + chWetL/R gains. Always in the
      // signal chain; mix=0 just zeroes the wet gains.
      const chorusDryL = this.ctx.createGain();
      const chorusDryR = this.ctx.createGain();
      const chorusDryMerger = this.ctx.createChannelMerger(2);
      const chorusInSplitter = this.ctx.createChannelSplitter(2);  // not used yet (mono in)
      const chorusDelayL = this.ctx.createDelay(0.05);
      const chorusDelayR = this.ctx.createDelay(0.05);
      const chLfoL = this.ctx.createOscillator();
      const chLfoR = this.ctx.createOscillator();
      chLfoL.type = "sine"; chLfoR.type = "sine";
      const chLfoLGain = this.ctx.createGain();   // depth → delay-time modulation
      const chLfoRGain = this.ctx.createGain();
      const chCenterL = this.ctx.createConstantSource();  // base delay (~8 ms)
      const chCenterR = this.ctx.createConstantSource();
      const chorusWetL = this.ctx.createGain();
      const chorusWetR = this.ctx.createGain();
      const chorusOutMerger = this.ctx.createChannelMerger(2);  // wet L+R stereo
      const chorusDry = this.ctx.createGain();                  // mono dry sum
      const chorusOut = this.ctx.createGain();                  // post-chorus mix bus

      const reverb = this.ctx.createConvolver();
      const reverbWet = this.ctx.createGain();
      const delayL = this.ctx.createDelay(2.0);
      const delayR = this.ctx.createDelay(2.0);
      const delayInR = this.ctx.createGain();   // filter → delayR gate (off in mono+pingPong)
      const fbSelfL  = this.ctx.createGain();    // delayL → delayL  (mono+stereo)
      const fbSelfR  = this.ctx.createGain();    // delayR → delayR  (stereo)
      const fbCrossLR = this.ctx.createGain();   // delayL → delayR  (pingPong)
      const fbCrossRL = this.ctx.createGain();   // delayR → delayL  (pingPong)
      const wetL2L = this.ctx.createGain();      // delayL → merger.L
      const wetL2R = this.ctx.createGain();      // delayL → merger.R (mono spread)
      const wetR2R = this.ctx.createGain();      // delayR → merger.R (stereo + pingPong)
      const delayMerger = this.ctx.createChannelMerger(2);
      const pan = this.ctx.createStereoPanner();
      const gain = this.ctx.createGain();

      // OscillatorNode only accepts sine/triangle/sawtooth/square. When the
      // voice's waveform is sample / whiteNoise / pinkNoise, the osc itself
      // is silenced via oscGain = 0; we keep it ticking on sine so FM still
      // has a periodic signal to reference if some other voice has us as
      // its FM source.
      const PERIODIC_TYPES = ["sine", "triangle", "sawtooth", "square"];
      const synthWaveform = PERIODIC_TYPES.includes(v.waveform) ? v.waveform : "sine";
      osc.type = synthWaveform;
      osc.frequency.value = v.frequencyHz;

      const f = v.filter || { type: "lowpass", cutoffHz: 4000, q: 0.7 };
      filter.type = f.type;
      filter.frequency.value = f.cutoffHz;
      filter.Q.value = f.q;

      pan.pan.value = v.pan;
      gain.gain.value = 0;  // fade in via setVoiceState

      // Three-way crossfade across osc / sample / noise so the active source
      // drives the chain at unity and the others sit at 0.
      const isSample = v.waveform === "sample";
      const isNoise  = (v.waveform === "whiteNoise" || v.waveform === "pinkNoise" || v.waveform === "granular");
      const isOsc    = !isSample && !isNoise;
      const isGranular = v.waveform === "granular";
      oscGain.gain.value    = isOsc    ? 1 : 0;
      sampleGain.gain.value = isSample ? 1 : 0;
      // Granular starts closed — the scheduler opens it per-grain.
      noiseGain.gain.value  = (isNoise && !isGranular) ? 1 : 0;

      // Per-voice drive — WaveShaperNode using a precomputed tanh curve.
      // drive = 1.0 → identity (no audible change). drive ∈ (1, 12] →
      // progressively warmer saturation; output normalized so peaks stay
      // around 1.0. Sits between the source merge and the filter so the
      // saturation creates harmonics that the LP filter can then tame —
      // exactly how amp + cab + EQ stacks behave.
      const drive = this.ctx.createWaveShaper();
      drive.curve = this._makeDriveCurve(v.drive || 1.0);
      drive.oversample = "2x";

      // Initial FX values from state (or defaults).
      const ch = v.chorus || { rateHz: 0.5, depth: 0.4, width: 0.7, mix: 0 };
      const fm = v.fm     || { sourceIndex: -1, index: 0 };
      const r = v.reverb || { decaySec: 2.0, mix: 0 };
      const d = v.delay  || { timeSec: 0.30, feedback: 0.40, mix: 0, mode: "mono", timing: "free" };
      reverb.buffer = buildReverbIR(this.ctx, r.decaySec);
      reverbWet.gain.value = r.mix;
      delayL.delayTime.value = d.timeSec;
      delayR.delayTime.value = d.timeSec;

      // Chorus initial values (audio nodes are wired below). depth=0.4 maps
      // to a peak LFO swing of ~6 ms around the 8 ms base delay.
      const CHORUS_BASE_SEC = 0.008;    // 8 ms midpoint
      const CHORUS_MAX_SWING = 0.012;   // ±12 ms at depth=1
      chCenterL.offset.value = CHORUS_BASE_SEC;
      chCenterR.offset.value = CHORUS_BASE_SEC;
      chCenterL.start();
      chCenterR.start();
      chLfoL.frequency.value = ch.rateHz;
      chLfoR.frequency.value = ch.rateHz;
      chLfoLGain.gain.value = ch.depth * CHORUS_MAX_SWING;
      chLfoRGain.gain.value = ch.depth * CHORUS_MAX_SWING;
      // Counter-phase between L and R for stereo width. ch.width=1 → full π.
      chLfoR.start(this.ctx.currentTime + 0.0001);
      chLfoL.start(this.ctx.currentTime + 0.0001 + (ch.width * 0.5 / Math.max(0.01, ch.rateHz)));
      // Wet gains (per-channel) and dry gain are set by setChorusMix below.
      chorusDry.gain.value = 1.0 - ch.mix;
      chorusWetL.gain.value = ch.mix;
      chorusWetR.gain.value = ch.mix;
      chorusOut.gain.value = 1.0;

      // Routing:
      //   osc/sample → filter → chorus(dry+wet) → chorusOut
      //                              ├→ pan          (dry)
      //                              ├→ reverb → reverbWet → pan
      //                              ├→ delayL ─┐
      //                              └→ delayInR → delayR ─┤  (gates differ per mode)
      //                                         ┌────────┘
      //                                         └→ merger → gain
      // Sources → drive (waveshaper) → filter → … rest of chain.
      osc.connect(oscGain);
      noiseSrc.connect(noiseGain);
      noiseSrc.start();
      oscGain.connect(drive);
      sampleGain.connect(drive);
      // Noise → grainPan (per-grain stereo offset) → drive. In non-granular
      // modes grainPan is at 0 and acts as a no-op.
      noiseGain.connect(grainPan).connect(drive);
      drive.connect(filter);

      // — Chorus stage —
      // Dry path: filter → chorusDry → chorusOut.
      filter.connect(chorusDry).connect(chorusOut);
      // Wet path: filter → delayChL/R → chorusWetL/R → merger(L,R) → chorusOut.
      filter.connect(chorusDelayL);
      filter.connect(chorusDelayR);
      chorusDelayL.connect(chorusWetL).connect(chorusOutMerger, 0, 0);
      chorusDelayR.connect(chorusWetR).connect(chorusOutMerger, 0, 1);
      chorusOutMerger.connect(chorusOut);
      // LFO drives each delay's delayTime around CHORUS_BASE_SEC.
      chCenterL.connect(chorusDelayL.delayTime);
      chCenterR.connect(chorusDelayR.delayTime);
      chLfoL.connect(chLfoLGain).connect(chorusDelayL.delayTime);
      chLfoR.connect(chLfoRGain).connect(chorusDelayR.delayTime);

      chorusOut.connect(pan);                            // dry
      chorusOut.connect(reverb).connect(reverbWet).connect(pan);   // reverb wet send

      // Delay topology: chorusOut feeds both delays (delayR gated by delayInR
      // gain); each delay's output feeds back into both itself and the
      // other delay via four routing-gain nodes; both outputs land in the
      // merger as a true stereo pair.
      chorusOut.connect(delayL);
      chorusOut.connect(delayInR); delayInR.connect(delayR);

      delayL.connect(fbSelfL);  fbSelfL.connect(delayL);
      delayR.connect(fbSelfR);  fbSelfR.connect(delayR);
      delayL.connect(fbCrossLR); fbCrossLR.connect(delayR);
      delayR.connect(fbCrossRL); fbCrossRL.connect(delayL);

      delayL.connect(wetL2L); wetL2L.connect(delayMerger, 0, 0);
      delayL.connect(wetL2R); wetL2R.connect(delayMerger, 0, 1);
      delayR.connect(wetR2R); wetR2R.connect(delayMerger, 0, 1);
      delayMerger.connect(gain);

      pan.connect(gain);
      // Per-voice timing envelope: voice.envelopeGain is what implements
      // "start delay" + "play duration". The tick re-computes its target
      // value from the transport elapsed seconds and ramps it smoothly.
      // Defaults to 1.0 (voice plays immediately, plays forever).
      const envelopeGain = this.ctx.createGain();
      envelopeGain.gain.value = 1.0;
      gain.connect(envelopeGain);
      envelopeGain.connect(this.master);
      osc.start();

      // Apply the saved mode and the saved mix to the routing gains.
      // Default mode is "mono" when nothing was saved.
      const voiceObj = {
        osc, oscGain, sampleGain, sampleContGain, noiseSrc, noiseGain, grainPan, drive, fmInput, filter, pan, gain, envelopeGain,
        chorusDry, chorusDelayL, chorusDelayR,
        chorusWetL, chorusWetR, chorusOutMerger, chorusOut,
        chLfoL, chLfoR, chLfoLGain, chLfoRGain, chCenterL, chCenterR,
        chorusBaseSec: CHORUS_BASE_SEC,
        chorusMaxSwing: CHORUS_MAX_SWING,
        reverb, reverbWet,
        delayL, delayR, delayInR,
        fbSelfL, fbSelfR, fbCrossLR, fbCrossRL,
        wetL2L, wetL2R, wetR2R, delayMerger,
        // FM patch state: which other voice modulates this carrier (if any),
        // the depth gain node that scales modulator output → frequency Hz,
        // and a reference back to the depth value so reroutes can rebuild.
        fmSourceIndex: -1,
        fmDepthGain: null,
        sampleSrc: null,         // AudioBufferSourceNode, created on loadSample
        sampleBuffer: null,      // decoded AudioBuffer
        // _effectiveFreq tracks the current playing frequency including pitch-LFO
        // modulation. Visualizations read this so the Chladni overlay morphs in
        // real time as vibrato plays. Initialized to the base freq; updated by
        // _applyLfosForVoice every tick.
        _effectiveFreq: v.frequencyHz,
        params: {
          freq: v.frequencyHz,
          amp: v.amplitude,
          pan: v.pan,
          waveform: v.waveform,
          muted: v.isMuted,
          soloed: v.isSoloed,
          filter: { ...f },
          chorus: { ...ch },
          fm: { ...fm },
          reverb: { ...r },
          delay: { ...d },
          // Timing envelope: voice silent for startDelaySec after transport
          // play, then 8s fade-in to full; if playDurationSec > 0, voice
          // fades out over 8s once it's played that long. 0 = no fade-out.
          startDelaySec: v.startDelaySec || 0,
          playDurationSec: v.playDurationSec || 0,
          // Replay cycles for the timing envelope. 1 = play once (the
          // v1.0 default), 2/3/5/10 = repeat N times, 0 = ∞.
          replayCount: (v.replayCount != null) ? v.replayCount : 1,
          // Granular synth params. Only audible when waveform === "granular".
          // The tick scheduler reads these on every tick to queue future
          // grain envelopes via setValueAtTime / linearRampToValueAtTime.
          grain: v.grain || { sizeMs: 80, densityHz: 8, jitter: 0.6, panSpread: 0.5 },
          // v1: granular SAMPLING. When sampleGranular is true and
          // waveform === "sample", the continuous sample loop is
          // muted and the grain scheduler spawns short AudioBufferSource
          // slices from the sample buffer at jittered positions —
          // same idea as iOS's sample-granular path. pos = center
          // read position [0..1], jitter randomizes ±jitter*0.5 around
          // pos for each grain.
          sampleGranular: !!v.sampleGranular,
          grainSamplePosFrac: (v.grainSamplePosFrac != null) ? v.grainSamplePosFrac : 0.5,
          grainSamplePosJitter: (v.grainSamplePosJitter != null) ? v.grainSamplePosJitter : 0.2,
          // v1: unity-pitch baseline for the loaded sample. Playback
          // rate is freq / sampleBaseFreqHz; when the voice's freq
          // equals this value, the sample plays at native rate.
          // Bundled samples and file uploads default to 220 Hz (their
          // historical baseline); recordings override to whatever
          // freq the OSC was at when the user hit Record.
          sampleBaseFreqHz: (v.sampleBaseFreqHz != null) ? v.sampleBaseFreqHz : 220,
          lfos: (v.lfos || [
            // v1.1 multi-target: targets is a SET (array) of
            // destinations. v1.0 wrote `target: "x"` — read/dispatch
            // handles either form for back-compat with old presets.
            { shape: "sine", targets: ["pan"],    rateHz: 0.25, depth: 0 },
            { shape: "sh",   targets: ["amp"],    rateHz: 0.50, depth: 0 },
            { shape: "sine", targets: ["cutoff"], rateHz: 0.30, depth: 0 },
            { shape: "sine", targets: ["pitch"],  rateHz: 0.30, depth: 0 }
          ]).map((l) => ({ ...l }))
        },
        _lfoPhase: [0, 0, 0, 0],
        _lfoHold: [0, 0, 0, 0],
        // Granular scheduler state: nextGrainTime is the audio-context time
        // at which the next grain should start. Scheduler runs each tick
        // and queues any grains falling within the next ~200ms.
        _nextGrainTime: 0,
        _audible: true
      };
      this.voices.push(voiceObj);
      // Apply the saved delay mode + mix to the routing gains now that
      // voiceObj is in place.
      this._applyDelayMode(this.voices.length - 1, d.mode || "mono", d.mix, d.feedback);
    }

    this.started = true;
    // Now that all 4 voices exist, wire any saved FM patches (cross-osc
    // routing has to wait for the modulator voice to exist).
    for (let i = 0; i < 4; i++) {
      const fm = (initialVoiceState[i] && initialVoiceState[i].fm) || { sourceIndex: -1, index: 0 };
      if (fm.sourceIndex >= 0 && fm.sourceIndex !== i) {
        this._applyFMPatch(i, fm.sourceIndex, fm.index);
      }
    }
    // Apply initial state so the gains ramp from 0 to their targets cleanly.
    this.applySoloMuteLogic();
    for (let i = 0; i < 4; i++) this.applyVoiceGain(i);

    this._lastTickTime = this.ctx.currentTime;
    // setInterval (not requestAnimationFrame) — rAF gets throttled to 1Hz when
    // the tab isn't focused, which would silently freeze LFO modulation while
    // the user has the window in the background.
    this._tickIntervalId = setInterval(this._tick, 33);  // ~30 Hz
    // Fade in is initiated by togglePlay, not here — that way the same engine
    // can be created by sample-loading code without auto-starting audio.
  }

  /// Smoothly ramp master from current value to the user's volume target.
  fadeInMaster(seconds = 3.0) {
    if (!this.ctx || !this.master) return;
    const t = this.ctx.currentTime;
    this.master.gain.cancelScheduledValues(t);
    this.master.gain.setValueAtTime(this.master.gain.value, t);
    this.master.gain.linearRampToValueAtTime(this.masterTarget, t + seconds);
  }

  // ─── Recording ──────────────────────────────────────────────────
  // Tap the post-limiter signal into a MediaStreamAudioDestinationNode and
  // run MediaRecorder on it. Output is WebM/Opus by default — universally
  // supported in modern browsers, small file size, no encode latency.
  startRecording() {
    if (!this.ctx || this.mediaRecorder) return false;
    if (!this.recordDest) {
      this.recordDest = this.ctx.createMediaStreamDestination();
      this.limiter.connect(this.recordDest);
    }
    const stream = this.recordDest.stream;
    // Prefer opus@128kbps when supported; fall back to the browser default.
    const mime = MediaRecorder.isTypeSupported("audio/webm;codecs=opus")
      ? "audio/webm;codecs=opus"
      : MediaRecorder.isTypeSupported("audio/webm")
        ? "audio/webm"
        : "";
    const opts = mime ? { mimeType: mime, audioBitsPerSecond: 128000 } : {};
    this.recordChunks = [];
    this.mediaRecorder = new MediaRecorder(stream, opts);
    this.mediaRecorder.ondataavailable = (e) => {
      if (e.data && e.data.size > 0) this.recordChunks.push(e.data);
    };
    this.mediaRecorder.start(1000);  // flush a chunk every second
    return true;
  }

  /// Stops recording, returning a Promise that resolves to a Blob (the
  /// captured WebM/Opus file) or null if nothing was recorded.
  stopRecording() {
    return new Promise((resolve) => {
      if (!this.mediaRecorder) return resolve(null);
      const rec = this.mediaRecorder;
      const mime = rec.mimeType || "audio/webm";
      rec.onstop = () => {
        const blob = new Blob(this.recordChunks, { type: mime });
        this.recordChunks = [];
        this.mediaRecorder = null;
        resolve(blob);
      };
      rec.stop();
    });
  }

  isRecording() {
    return !!(this.mediaRecorder && this.mediaRecorder.state === "recording");
  }

  /// Smoothly ramp master to silence over `seconds`, then resolve. Used by
  /// stop() and session auto-end so playback ends gently.
  async fadeOutMaster(seconds = 8.0) {
    if (!this.ctx || !this.master) return;
    const t = this.ctx.currentTime;
    this.master.gain.cancelScheduledValues(t);
    this.master.gain.setValueAtTime(this.master.gain.value, t);
    this.master.gain.linearRampToValueAtTime(0, t + seconds);
    await new Promise((r) => setTimeout(r, seconds * 1000 + 60));
  }

  _tick = () => {
    if (!this.ctx) return;
    const now = this.ctx.currentTime;
    const dt = Math.max(0, now - this._lastTickTime);
    this._lastTickTime = now;
    for (let i = 0; i < this.voices.length; i++) {
      this._applyLfosForVoice(i, dt, now);
      this._applyTimingEnvelope(i, now);
      this._scheduleGrains(i, now);
    }
  };

  // ───── Granular scheduler ─────
  /// For voices in granular mode, schedule a few grains' worth of envelope
  /// ramps ahead of `now`. Each grain is a triangular envelope on noiseGain
  /// (ramp up over half the grain, ramp down over the other half). Per-grain
  /// pan is randomized around 0 (the grainPan node sits in series before
  /// the voice's main pan, so the result is base_pan ± grainPanSpread).
  _scheduleGrains(i, now) {
    const v = this.voices[i];
    if (!v) return;
    // v1: now handles BOTH noise-granular (waveform === "granular") and
    // sample-granular (waveform === "sample" && sampleGranular === true).
    // The noise path triangle-envelopes the always-running noise source;
    // the sample path spawns short BufferSource slices from the sample
    // buffer at jittered positions.
    const isNoiseGran  = v.params.waveform === "granular";
    const isSampleGran = v.params.waveform === "sample"
                      && v.params.sampleGranular
                      && v.sampleBuffer;
    if (!isNoiseGran && !isSampleGran) return;

    const g = v.params.grain || { sizeMs: 80, densityHz: 8, jitter: 0.6, panSpread: 0.5 };
    // v1.1 LFO 5 grain modulation. Effective values fold in the
    // factors/biases the LFO loop wrote onto the voice (init 1.0 / 0
    // identity when LFO5 isn't targeting grain, so no-op for old
    // presets). Same clamps the engine enforces on the slider setters.
    const gSizeF   = v._lfo5GrainSizeFactor    || 1;
    const gDensF   = v._lfo5GrainDensityFactor || 1;
    const gJitMod  = v._lfo5GrainJitterMod     || 0;
    const gSprMod  = v._lfo5GrainSpreadMod     || 0;
    const effGSize    = Math.max(5,   Math.min(500, (g.sizeMs    || 80) * gSizeF));
    const effGDensity = Math.max(0.5, Math.min(50,  (g.densityHz || 8)  * gDensF));
    const effGJitter  = Math.max(0,   Math.min(1,   (g.jitter    || 0)  + gJitMod));
    const effGSpread  = Math.max(0,   Math.min(1,   (g.panSpread || 0)  + gSprMod));
    const LOOKAHEAD = 0.20;  // schedule grains starting within next 200 ms
    // Don't start grain trains until just before now if we've fallen behind
    // (e.g. after a long pause). Avoids piling up dozens of overdue grains.
    if (v._nextGrainTime < now - 0.05) v._nextGrainTime = now + 0.005;

    while (v._nextGrainTime < now + LOOKAHEAD) {
      const startT  = v._nextGrainTime;
      const lenSec  = Math.max(0.005, Math.min(0.500, effGSize / 1000));
      const halfLen = lenSec * 0.5;
      const endT    = startT + lenSec;

      if (isNoiseGran) {
        // Triangular envelope on noiseGain. Boost peak to 3.0 to
        // compensate for the duty-cycle silence so loudness sits in
        // the same neighborhood as continuous pink at the same amp
        // setting.
        try {
          v.noiseGain.gain.cancelScheduledValues(startT);
          v.noiseGain.gain.setValueAtTime(0, startT);
          v.noiseGain.gain.linearRampToValueAtTime(3.0, startT + halfLen);
          v.noiseGain.gain.linearRampToValueAtTime(0, endT);
        } catch {}
      } else {
        // SAMPLE-granular path: spawn one AudioBufferSource per grain,
        // gated by its own triangular envelope + its own StereoPanner.
        // The shared grainPan node (used by noise-granular) sits only
        // on the noise bus — so for sample-granular each grain needs
        // its OWN per-grain panner to honor the spread slider. Web
        // Audio kills these nodes after stop() so we don't need to
        // recycle.
        try {
          const buf = v.sampleBuffer;
          if (buf && buf.duration > 0) {
            const grainSrc = this.ctx.createBufferSource();
            grainSrc.buffer = buf;
            // v1 fix: use v._effectiveFreq (set every tick by the
            // LFO pass with pitch LFO + scale quantize + drift folded
            // in) instead of v.params.freq (just the base value).
            // Without this, recordings in granular mode ignored the
            // freq slider, pitch LFO, drift, and quantize-to-scale —
            // every grain spawned at its base captured pitch
            // regardless of what the modulation chain was doing.
            // Falls back to v.params.freq for safety.
            const liveFreq = (v._effectiveFreq && isFinite(v._effectiveFreq))
              ? v._effectiveFreq
              : v.params.freq;
            grainSrc.playbackRate.value = Math.max(0.05, Math.min(20, liveFreq / Math.max(20, v.params.sampleBaseFreqHz || 220)));
            const grainGain = this.ctx.createGain();
            grainGain.gain.value = 0;
            // Per-grain pan, sampled at grain start, held for the
            // grain's life — matches the noise-granular semantics.
            const grainPanner = this.ctx.createStereoPanner();
            const spread = Math.max(0, Math.min(1, effGSpread));
            grainPanner.pan.value = (Math.random() * 2 - 1) * spread;
            grainSrc.connect(grainGain).connect(grainPanner).connect(v.sampleGain);
            // Pick an offset around the user's center pos, jittered.
            const posCenter = Math.max(0, Math.min(1, v.params.grainSamplePosFrac || 0.5));
            const posJit    = Math.max(0, Math.min(1, v.params.grainSamplePosJitter || 0));
            const off = Math.max(0, Math.min(0.9999,
              posCenter + (Math.random() * 2 - 1) * posJit * 0.5));
            const startSec = off * buf.duration;
            // Triangular envelope on grainGain. 1.6× boost — Hann's
            // average power is ~0.5 and sample-grain duty cycle is
            // ~0.5 at default density, so without a boost the
            // sampled material sounds softer than expected vs
            // continuous playback.
            grainGain.gain.setValueAtTime(0, startT);
            grainGain.gain.linearRampToValueAtTime(1.6, startT + halfLen);
            grainGain.gain.linearRampToValueAtTime(0, endT);
            grainSrc.start(startT, startSec);
            grainSrc.stop(endT + 0.02);
          }
        } catch {}
      }

      // Per-grain pan for the noise-granular path. SAMPLE-granular
      // handles its own per-grain pan inline above, since the shared
      // grainPan node only sits on the noise bus.
      if (isNoiseGran) {
        const spread = Math.max(0, Math.min(1, effGSpread));
        const panOffset = (Math.random() * 2 - 1) * spread;
        try {
          v.grainPan.pan.cancelScheduledValues(startT);
          v.grainPan.pan.setValueAtTime(panOffset, startT);
        } catch {}
      }

      // Schedule the next grain. Mean gap from density; jitter randomizes
      // multiplicatively so high-jitter sounds Poisson-y.
      const meanGap = 1.0 / Math.max(0.5, effGDensity);
      const jit = Math.max(0, Math.min(1, effGJitter));
      const lo = Math.max(0.05, 1 - jit * 0.7);
      const hi = 1 + jit * 1.5;
      const gap = meanGap * (lo + Math.random() * (hi - lo));
      // When overlap is allowed, honor the gap literally — big grains
      // will trigger overlapping copies at the requested rate. Default
      // (false) clamps the gap to grain length so one grain finishes
      // before the next starts (legible rhythm at the cost of slowing
      // the effective trigger rate when grains are large).
      const allowOverlap = !!g.allowOverlap;
      v._nextGrainTime = startT + (allowOverlap
        ? Math.max(0.001, gap)
        : Math.max(lenSec + 0.005, gap));
    }
  }

  // ───── Granular setters ─────
  setGrainSize(index, ms) {
    const v = this.voices[index]; if (!v) return;
    if (!v.params.grain) v.params.grain = { sizeMs: 80, densityHz: 8, jitter: 0.6, panSpread: 0.5 };
    v.params.grain.sizeMs = Math.max(5, Math.min(500, ms));
  }
  setGrainDensity(index, hz) {
    const v = this.voices[index]; if (!v) return;
    if (!v.params.grain) v.params.grain = { sizeMs: 80, densityHz: 8, jitter: 0.6, panSpread: 0.5 };
    v.params.grain.densityHz = Math.max(0.5, Math.min(50, hz));
  }
  setGrainJitter(index, j) {
    const v = this.voices[index]; if (!v) return;
    if (!v.params.grain) v.params.grain = { sizeMs: 80, densityHz: 8, jitter: 0.6, panSpread: 0.5 };
    v.params.grain.jitter = Math.max(0, Math.min(1, j));
  }
  setGrainPanSpread(index, s) {
    const v = this.voices[index]; if (!v) return;
    if (!v.params.grain) v.params.grain = { sizeMs: 80, densityHz: 8, jitter: 0.6, panSpread: 0.5 };
    v.params.grain.panSpread = Math.max(0, Math.min(1, s));
  }
  /// v1: per-voice grain overlap toggle. See main.js
  /// actions.setGrainAllowOverlap and the scheduler scheduleGrains.
  setGrainAllowOverlap(index, on) {
    const v = this.voices[index]; if (!v) return;
    if (!v.params.grain) v.params.grain = { sizeMs: 80, densityHz: 8, jitter: 0.6, panSpread: 0.5 };
    v.params.grain.allowOverlap = !!on;
  }

  // ───── Metronome ─────
  // Toggle a sample-accurate quarter-note click locked to the current
  // BPM, routed post-master so it stays audible regardless of master
  // volume. Useful for verifying BPM-quantized grain density and
  // delay-time sync by ear.
  setMetronomeOn(on) {
    if (!this.ctx) return;
    const m = this.metronome;
    if (!m) return;
    if (on && !m.enabled) {
      // Browsers (Safari especially) hold a freshly-created
      // AudioContext in "suspended" state until a user gesture
      // resumes it, and may re-suspend after periods of silence.
      // Resume here AND inside the tick so the metronome stays
      // alive both on the very first toggle and across the
      // browser's auto-suspend windows.
      if (this.ctx.state === "suspended") {
        this.ctx.resume().catch(() => {});
      }
      m.enabled = true;
      m.beatCounter = 0;
      // Small head-room so the first click doesn't land at the same
      // sample as the toggle — gives WebAudio time to schedule.
      m.nextBeatTime = this.ctx.currentTime + 0.08;
      // Keep the scheduler simple: a setInterval pumps the look-ahead
      // window every tickIntervalMs. Inside the window we schedule
      // all due beats via WebAudio's sample-accurate `start(t)`. This
      // is the canonical "two-clock" pattern from the WebAudio book.
      m.timer = setInterval(() => this._metronomeTick(), m.tickIntervalMs);
    } else if (!on && m.enabled) {
      m.enabled = false;
      if (m.timer) { clearInterval(m.timer); m.timer = null; }
    }
  }
  setMetronomeBPM(bpm) {
    if (!this.metronome) return;
    const clamped = Math.max(30, Math.min(240, bpm));
    this.metronome.bpm = clamped;
    // Note: existing already-scheduled clicks fire at their old
    // times; subsequent beats use the new bpm. That's the right
    // feel — no jarring re-anchor — for a verify-by-ear tool.
  }
  /// v1: anchor metronome phase to the next render frame so beat 1
  /// (the accent) lands at currentTime + tiny head-room. Combined
  /// with resetGrainPhases() this means beat 1 of the click and
  /// grain 1 of every BPM-quantized voice land on the same audio
  /// sample. The user perceives this as "the metronome and the
  /// granular texture started together, locked, downbeat aligned."
  resetMetronomePhase() {
    if (!this.ctx || !this.metronome) return;
    const now = this.ctx.currentTime;
    this.metronome.beatCounter = 0;
    // 30 ms head-room so WebAudio can schedule the first click in
    // time. _metronomeTick will pick this up on its next interval.
    this.metronome.nextBeatTime = now + 0.03;
  }
  /// v1: anchor every voice's grain phase so the next grain fires
  /// immediately at the same anchor moment as resetMetronomePhase().
  /// Phase-locks BPM-quantized grains to metronome beat 1.
  resetGrainPhases() {
    if (!this.ctx) return;
    const now = this.ctx.currentTime;
    const t = now + 0.03;
    for (const v of this.voices) {
      if (!v) continue;
      v._nextGrainTime = t;
    }
  }
  _metronomeTick() {
    if (!this.ctx || !this.metronome.enabled) return;
    const ctx = this.ctx;
    // If the browser silently auto-suspended the ctx (Safari does
    // this aggressively when there's no significant audio activity),
    // currentTime freezes and the schedule-ahead window would never
    // advance. Bailing this tick after a resume() call wakes the
    // ctx up and the next tick (25 ms later) schedules normally.
    // Without this guard, the metronome clicks once or twice and
    // then goes silent forever.
    if (ctx.state === "suspended") {
      ctx.resume().catch(() => {});
      return;
    }
    const m = this.metronome;
    const beatLen = 60 / Math.max(30, m.bpm);
    while (m.nextBeatTime < ctx.currentTime + m.lookahead) {
      this._scheduleMetronomeClick(m.nextBeatTime, m.beatCounter === 0);
      m.nextBeatTime += beatLen;
      m.beatCounter = (m.beatCounter + 1) % 4;
    }
  }
  _scheduleMetronomeClick(t, accent) {
    const ctx = this.ctx;
    const osc = ctx.createOscillator();
    const gain = ctx.createGain();
    osc.type = "sine";
    // Accent on beat 1: brighter pitch, ~3 dB louder. Off-beats a
    // perfect fourth lower for a clean two-tone metronome cadence.
    osc.frequency.value = accent ? 1500 : 1000;
    const peak = accent ? 1.0 : 0.7;
    // Short envelope: 2 ms attack, ~55 ms exp decay. Just enough to
    // read as a "tick" without ringing into the next subdivision.
    gain.gain.setValueAtTime(0, t);
    gain.gain.linearRampToValueAtTime(peak, t + 0.002);
    gain.gain.exponentialRampToValueAtTime(0.0001, t + 0.055);
    osc.connect(gain).connect(this.metronome.bus);
    osc.start(t);
    osc.stop(t + 0.08);
  }

  // v1: granular SAMPLING setters. Active only when waveform === "sample".
  // setSampleGranular toggles the mode; setGrainSamplePos / Jitter control
  // where each grain reads from inside the sample buffer.
  setSampleGranular(index, on) {
    const v = this.voices[index]; if (!v) return;
    v.params.sampleGranular = !!on;
    // Mute the continuous source bus (sampleContGain) when granular is
    // on. Grain bursts go directly to sampleGain so they're audible
    // independently. Quick 30 ms ramp so the toggle doesn't click.
    if (this.ctx && v.sampleContGain) {
      try {
        const t = this.ctx.currentTime;
        v.sampleContGain.gain.cancelScheduledValues(t);
        v.sampleContGain.gain.setValueAtTime(v.sampleContGain.gain.value, t);
        v.sampleContGain.gain.linearRampToValueAtTime(on ? 0 : 1, t + 0.030);
      } catch {}
    }
  }
  setGrainSamplePos(index, frac) {
    const v = this.voices[index]; if (!v) return;
    v.params.grainSamplePosFrac = Math.max(0, Math.min(1, frac));
  }
  setGrainSamplePosJitter(index, frac) {
    const v = this.voices[index]; if (!v) return;
    v.params.grainSamplePosJitter = Math.max(0, Math.min(1, frac));
  }
  /// v1: set the unity-pitch baseline for the loaded sample.
  /// Bundled / file uploads default to 220 (back-compat); recordings
  /// override to the freq the OSC was at when the user hit Record.
  /// Re-applies the live playbackRate so the change takes effect
  /// immediately on the running continuous source.
  setSampleBaseFreqHz(index, hz) {
    const v = this.voices[index]; if (!v) return;
    v.params.sampleBaseFreqHz = Math.max(20, Math.min(8000, hz));
    if (this.ctx && v.sampleSrc && !v.params.sampleGranular) {
      try {
        const rate = Math.max(0.05, Math.min(20, v.params.freq / v.params.sampleBaseFreqHz));
        const t = this.ctx.currentTime;
        v.sampleSrc.playbackRate.cancelScheduledValues(t);
        v.sampleSrc.playbackRate.setValueAtTime(rate, t);
      } catch {}
    }
  }

  /// Per-voice timing envelope, driven by transportElapsed:
  ///   t < startDelay                                → silent
  ///   startDelay      ≤ t < startDelay + fadeIn    → fade in
  ///   fadeIn done     ≤ t < startDelay + playDur   → full volume
  ///   playDur reached ≤ t < playDur + fadeOut      → fade out (10 s)
  /// In cycling mode (replayCount != 1) the cycle wraps back to silent
  /// after the fadeOut tail and re-fades-in for the next pass.
  ///
  /// Mirrors iOS Voice.swift behavior:
  ///   • fadeInFirst = 8 s (first cycle — slow meditative onset)
  ///   • fadeInLoop  = 4 s (subsequent cycles — snappier rebloom)
  ///   • fadeOut     = 10 s (linear taper at the end of each playDur)
  /// Previously web used FADE = 8 for both directions AND set
  /// cycleLen = startDelay + playDur — the modulo wrapped at the
  /// instant playDur ended, so the fade-out branch was dead code in
  /// cycling mode and voices hard-cut at each play-duration boundary.
  /// Now cycleLen includes the fadeOut tail so the taper actually
  /// plays before the next cycle's fade-in starts.
  _applyTimingEnvelope(i, nowAudioTime) {
    const v = this.voices[i]; if (!v || !v.envelopeGain) return;
    const startDelay = v.params.startDelaySec || 0;
    const playDur    = v.params.playDurationSec || 0;
    const replayCount = (v.params.replayCount != null) ? v.params.replayCount : 1;
    const elapsed    = this.transportElapsed;
    // Default-skip: no envelope settings AND transport stopped → leave at 1.0.
    if (startDelay <= 0 && playDur <= 0) {
      if (v._envTarget !== 1) {
        v._envTarget = 1;
        const t = nowAudioTime;
        v.envelopeGain.gain.cancelScheduledValues(t);
        v.envelopeGain.gain.linearRampToValueAtTime(1, t + 0.05);
      }
      return;
    }
    const FADE_IN_FIRST = 8.0;   // first cycle — slow meditative onset
    const FADE_IN_LOOP  = 4.0;   // cycles 2+ — snappier rebloom
    const FADE_OUT      = 10.0;  // linear taper at end of each playDur
    let target = 1.0;
    if (!isFinite(elapsed)) {
      // Transport stopped/paused — leave whatever was there. The master
      // fadeOut covers actual silence; we don't fight it here.
      return;
    } else {
      // Cycle-modular time when replayCount != 1. Each cycle =
      // startDelay (silence) + playDur (audible, fade-in + full) +
      // FADE_OUT (taper before the next cycle starts). After all
      // repeats finish, env is silent forever. ∞ (replayCount === 0)
      // just keeps cycling — the master fade-out at session end
      // handles real silence.
      const cycleLen = startDelay + Math.max(0, playDur) + FADE_OUT;
      const infiniteReplay = (replayCount === 0);
      const useCycles = (replayCount !== 1) && playDur > 0 && cycleLen > 0;
      let t;
      let cycleIdx = 0;
      let beyondAll = false;
      if (useCycles) {
        cycleIdx = Math.floor(elapsed / cycleLen);
        if (!infiniteReplay && cycleIdx >= replayCount) {
          beyondAll = true;
          t = 0;
        } else {
          t = elapsed - cycleIdx * cycleLen;
        }
      } else {
        t = elapsed;
      }
      const activeFadeIn = (cycleIdx > 0) ? FADE_IN_LOOP : FADE_IN_FIRST;
      if (beyondAll) {
        target = 0;
      } else if (t < startDelay) {
        target = 0;
      } else if (t < startDelay + activeFadeIn) {
        target = (t - startDelay) / activeFadeIn;
      } else if (playDur > 0 && t >= startDelay + playDur) {
        // Fade-out portion of the cycle (or one-shot ending). Linear
        // taper for a continuous perceived fall — matches iOS's
        // post-v1.0 behavior (smoothstep felt like nothing was
        // happening for ~3 s then a sudden drop).
        const fadeOutElapsed = t - (startDelay + playDur);
        target = fadeOutElapsed >= FADE_OUT ? 0 : 1 - (fadeOutElapsed / FADE_OUT);
      } else {
        target = 1;
      }
    }
    if (v._envTarget == null || Math.abs(v._envTarget - target) > 0.005) {
      v._envTarget = target;
      const t = nowAudioTime;
      v.envelopeGain.gain.cancelScheduledValues(t);
      v.envelopeGain.gain.setValueAtTime(v.envelopeGain.gain.value, t);
      // Shorter than the FADE window above on purpose — tick is ~30 Hz, so
      // 0.15 s per ramp segment is plenty smooth and lets the envelope
      // shape itself by accumulating many tiny ramps.
      v.envelopeGain.gain.linearRampToValueAtTime(target, t + 0.15);
    }
  }

  _applyLfosForVoice(i, dt, now) {
    const v = this.voices[i];
    // Accumulate per-target modulation so multiple LFOs can sum into the same destination.
    let panMod = 0;
    let ampScale = 1.0;
    let cutoffOct = 0;       // additive octaves of cutoff modulation
    let pitchSemitones = 0;  // additive semitones of pitch modulation
    let qOct = 0;            // additive octaves of filter Q modulation (v1.1)
    let fmIndexMod = 0;      // additive Hz of FM index modulation (v1.1)
    let fxMixMod = 0;        // v1 FX Mix macro — bias for reverb+delay+chorus mixes
    // v1.1 LFO 5 accumulators. Multiplicative factors start at 1.0 so
    // a depth-0 LFO5 vanishes; additive mods start at 0.
    let grainSizeFactor    = 1.0;
    let grainDensityFactor = 1.0;
    let grainJitterMod     = 0;
    let grainSpreadMod     = 0;
    let delayTimeFactor    = 1.0;
    let reverbMixMod       = 0;
    // The other three LFO 5 targets (.reverbDecay, .delayFeedback,
    // .delayMix) ship iOS-only for v1.1 — Web Audio would need an IR
    // buffer rebuild or _applyDelayMode router rerun every render
    // tick, both of which would crackle. Roadmap item to revisit
    // with offline IR caching + persistent feedback-tap gain nodes.
    let anyPan = false, anyAmp = false, anyCutoff = false, anyPitch = false;
    let anyQ = false, anyFm = false, anyFxMix = false;
    let anyGrainMod = false, anyDelayTime = false, anyReverbMix = false;

    for (let k = 0; k < 5; k++) {
      const lfo = v.params.lfos[k];
      // v1.1: tolerate old 4-LFO presets — _padLfos pads on first
      // setter touch but the LFO loop runs every render tick even
      // before the user touches LFO 5. Treat missing as silent.
      if (!lfo || lfo.depth < 0.001) continue;

      v._lfoPhase[k] += lfo.rateHz * dt;
      let stepped = false;
      if (v._lfoPhase[k] >= 1) {
        v._lfoPhase[k] -= Math.floor(v._lfoPhase[k]);
        stepped = true;
      }
      let lfoValue;
      if (lfo.shape === "sine") {
        lfoValue = Math.sin(v._lfoPhase[k] * 2 * Math.PI);
      } else if (lfo.shape === "triangle") {
        // Linear ↗↘ — smoother than square, less rounded than sine.
        const p = v._lfoPhase[k];
        lfoValue = p < 0.5 ? (4 * p - 1) : (3 - 4 * p);
      } else if (lfo.shape === "square") {
        // Square wave: +1 first half of the cycle, -1 second half. Abrupt
        // transitions — useful as a gate/tremolo when routed to amp.
        lfoValue = v._lfoPhase[k] < 0.5 ? 1 : -1;
      } else if (lfo.shape === "sawtooth") {
        // Rising sawtooth: linear -1 → +1 over the phase, then jumps back.
        // Classic upward sweep for filter sweeps, pitch rises, etc.
        lfoValue = 2 * v._lfoPhase[k] - 1;
      } else if (lfo.shape === "ramp") {
        // Falling ramp (inverse sawtooth): +1 → -1 then jumps back.
        // Mirror of sawtooth; envelope-like attack-then-decay sweeps.
        lfoValue = 1 - 2 * v._lfoPhase[k];
      } else {
        // sample-and-hold (id "sh")
        if (stepped || v._lfoHold[k] == null || v._lfoHold[k] === 0) {
          v._lfoHold[k] = Math.random() * 2 - 1;
        }
        lfoValue = v._lfoHold[k];
      }

      // v1.1 multi-target: each LFO can drive multiple destinations
      // simultaneously. Backward compat: if lfo.targets is missing
      // (v1.0 preset / state), wrap lfo.target into a single-element
      // array.
      const targets = Array.isArray(lfo.targets) ? lfo.targets
        : (lfo.target ? [lfo.target] : []);
      for (const target of targets) {
        if (target === "pan") {
          panMod += lfo.depth * lfoValue;
          anyPan = true;
        } else if (target === "amp") {
          ampScale *= (1 + 0.6 * lfo.depth * lfoValue);
          anyAmp = true;
        } else if (target === "cutoff") {
          cutoffOct += 2 * lfo.depth * lfoValue;
          anyCutoff = true;
        } else if (target === "pitch") {
          // Pitch swing widens when quantize-to-scale is on so the
          // LFO can actually reach distant chord notes. ±2 semis is
          // vibrato range and only snaps to the 1-2 nearest scale
          // degrees; ±12 semis (1 octave) gives full chord-range
          // arpeggiation with S&H.
          const pitchSpan = v.pitchQuantizeToScale ? 12 : 2;
          pitchSemitones += pitchSpan * lfo.depth * lfoValue;
          anyPitch = true;
        } else if (target === "q") {
          qOct += 1.5 * lfo.depth * lfoValue;
          anyQ = true;
        } else if (target === "fm") {
          fmIndexMod += 200 * lfo.depth * lfoValue;
          anyFm = true;
        } else if (target === "fxMix") {
          // v1 FX Mix macro: ±0.5 bias on the wet bus (reverb + delay
          // + chorus mixes together). Applied additively to each FX
          // mix at its read site below, clamped 0..1. A "swell" macro
          // — one LFO modulates the entire wet bus together.
          fxMixMod += 0.5 * lfo.depth * lfoValue;
          anyFxMix = true;
        // v1.1 LFO 5 targets. String IDs match iOS LfoState.Target raw
        // values exactly so .dronepreset files round-trip without
        // translation. The three iOS-only targets (.reverbDecay,
        // .delayFeedback, .delayMix) are accepted silently so loading
        // a cross-platform preset doesn't error — they just no-op on
        // web for v1.1.
        } else if (target === "grainSize") {
          grainSizeFactor *= (1 + 0.5 * lfo.depth * lfoValue);
          anyGrainMod = true;
        } else if (target === "grainDensity") {
          grainDensityFactor *= (1 + 0.5 * lfo.depth * lfoValue);
          anyGrainMod = true;
        } else if (target === "grainJitter") {
          grainJitterMod += 0.5 * lfo.depth * lfoValue;
          anyGrainMod = true;
        } else if (target === "grainSpread") {
          grainSpreadMod += 0.5 * lfo.depth * lfoValue;
          anyGrainMod = true;
        } else if (target === "delayTime") {
          // ±15% (matches iOS). Bigger swings + fast LFO shapes
          // overrun the AudioParam ramp and produce Doppler chirps.
          delayTimeFactor *= (1 + 0.15 * lfo.depth * lfoValue);
          anyDelayTime = true;
        } else if (target === "reverbMix") {
          reverbMixMod += 0.5 * lfo.depth * lfoValue;
          anyReverbMix = true;
        } else if (target === "reverbDecay" || target === "delayFeedback" || target === "delayMix") {
          // Cross-platform compat — preset can specify these, no-op on web.
        }
      }
    }

    // Always recompute effective freq, even when no pitch LFO is active —
    // visualizations read this and need it to track UI freq changes too.
    v._effectiveFreq = v.params.freq * Math.pow(2, pitchSemitones / 12);

    if (anyPan) {
      const panEff = Math.max(-1, Math.min(1, v.params.pan + panMod));
      v.pan.pan.cancelScheduledValues(now);
      v.pan.pan.setValueAtTime(v.pan.pan.value, now);
      v.pan.pan.linearRampToValueAtTime(panEff, now + LFO_SMOOTH);
    }
    if (anyAmp) {
      const base = v._audible === false ? 0 : v.params.amp;
      const ampEff = Math.max(0, Math.min(1, base * ampScale));
      v.gain.gain.cancelScheduledValues(now);
      v.gain.gain.setValueAtTime(v.gain.gain.value, now);
      v.gain.gain.linearRampToValueAtTime(ampEff, now + LFO_SMOOTH);
    }
    if (anyCutoff) {
      const cutoffEff = Math.max(20, Math.min(8000, v.params.filter.cutoffHz * Math.pow(2, cutoffOct)));
      v.filter.frequency.cancelScheduledValues(now);
      v.filter.frequency.setValueAtTime(v.filter.frequency.value, now);
      v.filter.frequency.linearRampToValueAtTime(cutoffEff, now + LFO_SMOOTH);
    }
    if (anyPitch || v.pitchQuantizeToScale) {
      const pitchMult = Math.pow(2, pitchSemitones / 12);
      let freqEff = Math.max(0.01, v.params.freq * pitchMult);
      // v1.1 quantize-to-scale: snap freqEff to the nearest entry in
      // the engine's scaleNotesHz cache (populated by main.js's
      // recomputeQuantizeScale on chord/tuning/key/octave change).
      // Snap in log space so the "nearest" measure is musically
      // meaningful (halfstep above and below count equidistant).
      if (v.pitchQuantizeToScale && this.scaleNotesHz && this.scaleNotesHz.length > 0) {
        const logTarget = Math.log2(freqEff);
        let bestNote = this.scaleNotesHz[0];
        let bestDiff = Math.abs(Math.log2(bestNote) - logTarget);
        for (const n of this.scaleNotesHz) {
          if (n <= 0) continue;
          const d = Math.abs(Math.log2(n) - logTarget);
          if (d < bestDiff) { bestDiff = d; bestNote = n; }
        }
        freqEff = bestNote;
        // v1 fix: write the snapped value back to _effectiveFreq so
        // downstream readers (grain spawn, sand sim, Chladni) see
        // the quantized pitch. Previously the snap only landed on
        // osc.frequency and the continuous sample's playbackRate;
        // sample-granular grains kept reading v._effectiveFreq with
        // the pre-snap pitch and ignored quantize-to-scale.
        v._effectiveFreq = freqEff;
      }
      v.osc.frequency.cancelScheduledValues(now);
      v.osc.frequency.setValueAtTime(v.osc.frequency.value, now);
      v.osc.frequency.linearRampToValueAtTime(freqEff, now + LFO_SMOOTH);
      // Apply to sample playback rate too, so loaded samples vibrato
      // along. v1 BUGFIX: skip when sample-granular is on — the
      // continuous sampleSrc is gain-muted via sampleContGain in that
      // mode, but touching its playbackRate appears to cause some
      // browsers to route the continuous loop's PCM through anyway
      // (user reported the continuous sample becoming audible on top
      // of grains when an LFO with pitch target was enabled). Also
      // fix the hardcoded 220 → sampleBaseFreqHz so the LFO honors
      // the recording's unity-pitch baseline.
      if (v.sampleSrc && !v.params.sampleGranular) {
        const baseFreq = Math.max(20, v.params.sampleBaseFreqHz || 220);
        const rateEff = Math.max(0.05, Math.min(20, freqEff / baseFreq));
        v.sampleSrc.playbackRate.cancelScheduledValues(now);
        v.sampleSrc.playbackRate.setValueAtTime(v.sampleSrc.playbackRate.value, now);
        v.sampleSrc.playbackRate.linearRampToValueAtTime(rateEff, now + LFO_SMOOTH);
      }
    }
    if (anyQ) {
      // ±1.5 octaves of Q at depth=1 — multiplicative in log-Q space.
      // Clamp to the BiquadFilterNode's stable range (Q can go to ~30+
      // but starts ringing into oscillation; our slider tops at 20).
      const qEff = Math.max(0.3, Math.min(20, v.params.filter.q * Math.pow(2, qOct)));
      v.filter.Q.cancelScheduledValues(now);
      v.filter.Q.setValueAtTime(v.filter.Q.value, now);
      v.filter.Q.linearRampToValueAtTime(qEff, now + LFO_SMOOTH);
    }
    if (anyFm) {
      // FM index in Hz; clamp to the slider range [0, 800]. The depth
      // gain node (set up in _applyFMPatch) carries the index value —
      // ramping it ramps the FM amount. No-op if no FM source is
      // currently patched (fmDepthGain only exists when source >= 0).
      const fmEff = Math.max(0, Math.min(800, v.params.fm.index + fmIndexMod));
      if (v.fmDepthGain) {
        v.fmDepthGain.gain.cancelScheduledValues(now);
        v.fmDepthGain.gain.setValueAtTime(v.fmDepthGain.gain.value, now);
        v.fmDepthGain.gain.linearRampToValueAtTime(fmEff, now + LFO_SMOOTH);
      }
    }
    // v1 FX Mix macro. Applies the per-buffer LFO bias to the wet bus
    // nodes — reverb + chorus on web. (Delay's routing goes through
    // _applyDelayMode and isn't a single gain node we can write to
    // without re-running the router; documented gap, can be added
    // later. The "swell" feel still reads with two of three wet
    // effects moving together.)
    //
    // We always overwrite when anyFxMix was set this buffer OR was
    // set the previous buffer — that way the turn-off transition
    // re-writes the base value once, after which the regular slider-
    // drag setters take over again.
    if (anyFxMix || v._fxMixWasActive) {
      const baseRev = v.params.reverb.mix || 0;
      const baseCh = v.params.chorus.mix || 0;
      const effRev = Math.max(0, Math.min(1, baseRev + fxMixMod));
      const effCh = Math.max(0, Math.min(1, baseCh + fxMixMod));
      v.reverbWet.gain.cancelScheduledValues(now);
      v.reverbWet.gain.setValueAtTime(effRev, now);
      v.chorusWetL.gain.cancelScheduledValues(now);
      v.chorusWetL.gain.setValueAtTime(effCh, now);
      v.chorusWetR.gain.cancelScheduledValues(now);
      v.chorusWetR.gain.setValueAtTime(effCh, now);
      v._fxMixWasActive = anyFxMix;
    }
    // v1.1 LFO 5 — grain mods are stored on the voice for the grain
    // scheduler (_scheduleGrains) to read on the next tick. Clamps
    // mirror the iOS engine's ranges (size 5..500ms, density 0.5..50,
    // jitter+spread 0..1). When no LFO5 grain target is active these
    // get reset to identity so a turn-off cleanly restores base values.
    if (anyGrainMod || v._lfo5GrainWasActive) {
      v._lfo5GrainSizeFactor    = anyGrainMod ? grainSizeFactor    : 1;
      v._lfo5GrainDensityFactor = anyGrainMod ? grainDensityFactor : 1;
      v._lfo5GrainJitterMod     = anyGrainMod ? grainJitterMod     : 0;
      v._lfo5GrainSpreadMod     = anyGrainMod ? grainSpreadMod     : 0;
      v._lfo5GrainWasActive = anyGrainMod;
    }
    // v1.1 LFO 5 — delay time direct AudioParam ramp. Per-buffer slew
    // is short enough to track moderate-rate LFOs but smooth enough to
    // avoid Doppler chirps. Same pattern as the chorus delayTime AudioParam.
    // Buffer-rate smoothing on the factor itself breaks up S&H/square
    // LFO steps so the tap doesn't jump hard between buffers — the
    // AudioParam ramp finishes the smoothing into chorus-y shimmer.
    if (anyDelayTime || v._lfo5DelayTimeWasActive) {
      if (v._smoothLfoDelayTimeFactor == null) v._smoothLfoDelayTimeFactor = 1;
      if (anyDelayTime) {
        v._smoothLfoDelayTimeFactor += (delayTimeFactor - v._smoothLfoDelayTimeFactor) * 0.10;
      } else {
        // Hard-snap to identity when LFO 5 stops modulating — same fix
        // as iOS Voice.swift. Asymptotic smoothing toward 1 in a single
        // buffer left a residual offset on the delay tap; snapping
        // guarantees the AudioParam returns to base exactly.
        v._smoothLfoDelayTimeFactor = 1;
      }
      const baseDly = Math.max(0.001, v.params.delay.timeSec || 0.3);
      const effDly = Math.max(0.001, Math.min(2.0, baseDly * v._smoothLfoDelayTimeFactor));
      if (v.delayL && v.delayL.delayTime) {
        v.delayL.delayTime.cancelScheduledValues(now);
        v.delayL.delayTime.setValueAtTime(v.delayL.delayTime.value, now);
        v.delayL.delayTime.linearRampToValueAtTime(effDly, now + LFO_SMOOTH);
      }
      if (v.delayR && v.delayR.delayTime) {
        v.delayR.delayTime.cancelScheduledValues(now);
        v.delayR.delayTime.setValueAtTime(v.delayR.delayTime.value, now);
        v.delayR.delayTime.linearRampToValueAtTime(effDly, now + LFO_SMOOTH);
      }
      v._lfo5DelayTimeWasActive = anyDelayTime;
    }
    // v1.1 LFO 5 — reverb mix direct ramp. Stacks with fxMix bias if
    // both are active (LFO 5 can fade JUST reverb while another LFO
    // sweeps the whole bus).
    if (anyReverbMix || v._lfo5ReverbMixWasActive) {
      if (v._smoothLfoReverbMixMod == null) v._smoothLfoReverbMixMod = 0;
      if (anyReverbMix) {
        v._smoothLfoReverbMixMod += (reverbMixMod - v._smoothLfoReverbMixMod) * 0.10;
      } else {
        // Hard-snap to 0 — see delayTime block above.
        v._smoothLfoReverbMixMod = 0;
      }
      const baseRev = v.params.reverb.mix || 0;
      const effRev = Math.max(0, Math.min(1, baseRev + v._smoothLfoReverbMixMod));
      v.reverbWet.gain.cancelScheduledValues(now);
      v.reverbWet.gain.setValueAtTime(v.reverbWet.gain.value, now);
      v.reverbWet.gain.linearRampToValueAtTime(effRev, now + LFO_SMOOTH);
      v._lfo5ReverbMixWasActive = anyReverbMix;
    }
  }

  /** Suspend audio (e.g. on Pause). */
  suspend() {
    if (this.ctx && this.ctx.state === "running") this.ctx.suspend();
  }

  /** Resume after suspend. */
  resume() {
    if (this.ctx && this.ctx.state === "suspended") this.ctx.resume();
  }

  /** Tear down and release the AudioContext. */
  async stop() {
    if (!this.ctx) return;
    if (this._tickIntervalId) { clearInterval(this._tickIntervalId); this._tickIntervalId = null; }
    // Ramp master to 0 then close, to avoid a tail click.
    const t = this.ctx.currentTime;
    this.master.gain.cancelScheduledValues(t);
    this.master.gain.setValueAtTime(this.master.gain.value, t);
    this.master.gain.linearRampToValueAtTime(0, t + 0.060);
    await new Promise((r) => setTimeout(r, 80));
    try {
      for (const v of this.voices) {
        v.osc.stop();
        v.osc.disconnect();
      }
      await this.ctx.close();
    } catch {}
    this.ctx = null;
    this.master = null;
    this.voices = [];
    this.started = false;
  }

  // ───── per-voice setters ─────────────────────────────────

  setFrequency(index, hz) {
    const v = this.voices[index]; if (!v) return;
    v.params.freq = hz;
    if (!this.ctx) return;
    const t = this.ctx.currentTime;
    v.osc.frequency.cancelScheduledValues(t);
    v.osc.frequency.setValueAtTime(v.osc.frequency.value, t);
    v.osc.frequency.exponentialRampToValueAtTime(Math.max(0.01, hz), t + RAMP_TIME);
    // When a sample is loaded, freq acts as the pitch shifter from
    // sampleBaseFreqHz (default 220 for bundled / file uploads;
    // record-time freq for recordings). v1 BUGFIX: skip when
    // sample-granular is on — the continuous source is gain-muted but
    // updating its playbackRate causes some browsers to route the
    // continuous loop audibly on top of the grains.
    if (v.sampleSrc && !v.params.sampleGranular) {
      const baseFreq = Math.max(20, v.params.sampleBaseFreqHz || 220);
      const rate = Math.max(0.05, Math.min(20, hz / baseFreq));
      v.sampleSrc.playbackRate.cancelScheduledValues(t);
      v.sampleSrc.playbackRate.setValueAtTime(v.sampleSrc.playbackRate.value, t);
      v.sampleSrc.playbackRate.linearRampToValueAtTime(rate, t + RAMP_TIME);
    }
  }

  setAmplitude(index, amp) {
    const v = this.voices[index]; if (!v) return;
    v.params.amp = amp;
    this.applyVoiceGain(index);
  }

  setPan(index, pan) {
    const v = this.voices[index]; if (!v) return;
    v.params.pan = pan;
    if (!this.ctx) return;
    const t = this.ctx.currentTime;
    v.pan.pan.cancelScheduledValues(t);
    v.pan.pan.setValueAtTime(v.pan.pan.value, t);
    v.pan.pan.linearRampToValueAtTime(pan, t + RAMP_TIME);
  }

  setWaveform(index, waveform) {
    const v = this.voices[index]; if (!v) return;
    const prevWaveform = v.params.waveform;
    v.params.waveform = waveform;
    if (!this.ctx) return;
    const t = this.ctx.currentTime;

    // Three-way crossfade across osc / sample / noise so exactly one source
    // is audible at a time. Granular is a sub-mode of noise — same noiseGain
    // path, but the scheduler keeps it mostly closed.
    const isSample   = waveform === "sample";
    const isGranular = waveform === "granular";
    const isNoise    = (waveform === "whiteNoise" || waveform === "pinkNoise" || isGranular);
    const isOsc      = !isSample && !isNoise;
    const ramp = (param, target) => {
      param.cancelScheduledValues(t);
      param.setValueAtTime(param.value, t);
      param.linearRampToValueAtTime(target, t + 0.020);
    };
    ramp(v.oscGain.gain,    isOsc    ? 1 : 0);
    ramp(v.sampleGain.gain, isSample ? 1 : 0);
    // For continuous noise: open to 1. For granular: close — scheduler will
    // open it per-grain. For non-noise: close.
    ramp(v.noiseGain.gain,  (isNoise && !isGranular) ? 1 : 0);

    // For noise: swap the buffer between white / pink / granular (uses pink)
    // when the active type changes. AudioBufferSourceNode lets you only set
    // buffer once OR while not started — so we hot-swap by stopping +
    // recreating the source.
    if (isNoise) {
      const wantPink = (waveform === "pinkNoise" || waveform === "granular");
      const wantBuffer = wantPink ? this._pinkNoiseBuffer() : this._whiteNoiseBuffer();
      if (v.noiseSrc.buffer !== wantBuffer) {
        try { v.noiseSrc.stop(); v.noiseSrc.disconnect(); } catch {}
        const ns = this.ctx.createBufferSource();
        ns.buffer = wantBuffer;
        ns.loop = true;
        ns.connect(v.noiseGain);
        ns.start();
        v.noiseSrc = ns;
      }
    }

    // Granular mode transition housekeeping.
    if (isGranular) {
      // (Re-)arm the scheduler. The tick will start firing grains.
      v._nextGrainTime = t + 0.02;
    } else if (prevWaveform === "granular") {
      // Leaving granular — cancel any scheduled grain ramps and re-center
      // grainPan so a future return finds a clean slate. Also force the
      // noiseGain ramp above to win.
      try {
        v.noiseGain.gain.cancelScheduledValues(t);
        v.noiseGain.gain.setValueAtTime(v.noiseGain.gain.value, t);
        v.noiseGain.gain.linearRampToValueAtTime(isNoise ? 1 : 0, t + 0.04);
        v.grainPan.pan.cancelScheduledValues(t);
        v.grainPan.pan.setValueAtTime(v.grainPan.pan.value, t);
        v.grainPan.pan.linearRampToValueAtTime(0, t + 0.04);
      } catch {}
    }

    // For periodic waveforms: brief dip on the master gain to hide the synth
    // osc's phase-reset click when changing osc.type.
    if (isOsc) {
      const target = v.gain.gain.value;
      v.gain.gain.cancelScheduledValues(t);
      v.gain.gain.setValueAtTime(target, t);
      v.gain.gain.linearRampToValueAtTime(target * 0.5, t + 0.008);
      v.osc.type = waveform;
      v.gain.gain.linearRampToValueAtTime(target, t + 0.024);
    }
  }

  // ───── Timing envelope (per-voice start delay + play duration) ─────
  setStartDelay(index, sec) {
    const v = this.voices[index]; if (!v) return;
    v.params.startDelaySec = Math.max(0, sec || 0);
    // Envelope is re-evaluated on every tick — no further action needed.
  }
  setPlayDuration(index, sec) {
    const v = this.voices[index]; if (!v) return;
    v.params.playDurationSec = Math.max(0, sec || 0);
  }
  /// Replay cycles for the timing envelope. 1 (default) = play once,
  /// 2/3/5/10 = repeat N times, 0 = ∞. Only meaningful when
  /// playDurationSec > 0 (otherwise the voice plays forever from the
  /// first cycle). Mirrors the iOS Voice.replayCount field.
  setReplayCount(index, count) {
    const v = this.voices[index]; if (!v) return;
    v.params.replayCount = Math.max(0, Math.min(99, Math.floor(count ?? 1)));
  }

  // ───── Drive (per-voice tanh saturation) ─────────────
  setDrive(index, driveAmount) {
    const v = this.voices[index]; if (!v) return;
    const clamped = Math.max(1.0, Math.min(12.0, driveAmount));
    v.params.drive = clamped;
    if (!this.ctx || !v.drive) return;
    v.drive.curve = this._makeDriveCurve(clamped);
  }

  /// Build a 256-point tanh waveshaping curve. drive=1 → identity (no
  /// audible change). drive>1 → progressively warmer saturation, output
  /// normalized so peaks stay around 1.0.
  _makeDriveCurve(driveAmount) {
    const n = 256;
    const curve = new Float32Array(n);
    if (driveAmount <= 1.001) {
      for (let i = 0; i < n; i++) curve[i] = (i * 2 / (n - 1)) - 1;
      return curve;
    }
    const norm = Math.tanh(driveAmount);
    for (let i = 0; i < n; i++) {
      const x = (i * 2 / (n - 1)) - 1;
      curve[i] = Math.tanh(driveAmount * x) / norm;
    }
    return curve;
  }

  /// Lazy shared 2-second white-noise loop. Reused across all voices —
  /// noise is stochastic so sharing the buffer doesn't produce correlated
  /// channels (each BufferSource starts at a different time).
  _whiteNoiseBuffer() {
    if (!this._whiteBuf) {
      const sr = this.ctx.sampleRate;
      const len = sr * 2;
      const buf = this.ctx.createBuffer(1, len, sr);
      const ch = buf.getChannelData(0);
      for (let i = 0; i < len; i++) ch[i] = Math.random() * 2 - 1;
      this._whiteBuf = buf;
    }
    return this._whiteBuf;
  }

  /// Lazy shared 2-second pink-noise loop via Paul Kellet's filter.
  _pinkNoiseBuffer() {
    if (!this._pinkBuf) {
      const sr = this.ctx.sampleRate;
      const len = sr * 2;
      const buf = this.ctx.createBuffer(1, len, sr);
      const ch = buf.getChannelData(0);
      let b0 = 0, b1 = 0, b2 = 0, b3 = 0, b4 = 0, b5 = 0, b6 = 0;
      for (let i = 0; i < len; i++) {
        const white = Math.random() * 2 - 1;
        b0 = 0.99886 * b0 + white * 0.0555179;
        b1 = 0.99332 * b1 + white * 0.0750759;
        b2 = 0.96900 * b2 + white * 0.1538520;
        b3 = 0.86650 * b3 + white * 0.3104856;
        b4 = 0.55000 * b4 + white * 0.5329522;
        b5 = -0.7616 * b5 - white * 0.0168980;
        ch[i] = (b0 + b1 + b2 + b3 + b4 + b5 + b6 + white * 0.5362) * 0.11;
        b6 = white * 0.115926;
      }
      this._pinkBuf = buf;
    }
    return this._pinkBuf;
  }

  /// Load (or replace) the sample for a voice. `audioBuffer` is a decoded AudioBuffer.
  loadSample(index, audioBuffer) {
    const v = this.voices[index]; if (!v || !this.ctx) return;
    // Stop and disconnect the previous sample source, if any.
    if (v.sampleSrc) {
      try { v.sampleSrc.stop(); } catch {}
      try { v.sampleSrc.disconnect(); } catch {}
    }
    v.sampleBuffer = audioBuffer;
    const src = this.ctx.createBufferSource();
    src.buffer = audioBuffer;
    src.loop = true;
    // Honour any pre-set play-window (sampleStartFrac, sampleEndFrac).
    // Defaults to whole-sample loop if no window was set.
    const startFrac = (v.params.sampleStartFrac != null) ? v.params.sampleStartFrac : 0;
    const endFrac = (v.params.sampleEndFrac != null) ? v.params.sampleEndFrac : 1;
    src.loopStart = audioBuffer.duration * Math.max(0, Math.min(0.999, startFrac));
    src.loopEnd = audioBuffer.duration * Math.max(0.001, Math.min(1, endFrac));
    src.playbackRate.value = Math.max(0.05, Math.min(20, v.params.freq / Math.max(20, v.params.sampleBaseFreqHz || 220)));
    // Continuous source routes through sampleContGain (split bus, see
    // the constructor) so setSampleGranular can mute it without
    // silencing concurrent grain bursts that go straight to sampleGain.
    src.connect(v.sampleContGain);
    // If the voice was already in granular mode (e.g. coming back from
    // a stop/play cycle, or applying a preset that uses granular
    // sampling), keep the continuous bus muted.
    v.sampleContGain.gain.value = v.params.sampleGranular ? 0 : 1;
    // Start playback from the window start so the first cycle plays the
    // user's selected region too (not just subsequent loops).
    src.start(0, src.loopStart);
    v.sampleSrc = src;
  }

  /// Update the sample play-window without reloading the buffer. Called
  /// when the user drags the start/end sliders.
  setSampleWindow(index, startFrac, endFrac) {
    const v = this.voices[index]; if (!v) return;
    if (v.params) {
      v.params.sampleStartFrac = startFrac;
      v.params.sampleEndFrac = endFrac;
    }
    if (v.sampleSrc && v.sampleBuffer) {
      v.sampleSrc.loopStart = v.sampleBuffer.duration * Math.max(0, Math.min(0.999, startFrac));
      v.sampleSrc.loopEnd = v.sampleBuffer.duration * Math.max(0.001, Math.min(1, endFrac));
    }
  }

  /// Fade-in / fade-out seconds at the loop boundary. v1 web stores these
  /// on the voice for preset persistence + morph plumbing but does NOT
  /// audibly apply them — AudioBufferSourceNode has no native crossfade.
  /// A v1.1 follow-up could implement scheduled-gain crossfades using
  /// the loop period and the audio clock. iOS implements the full
  /// crossfade in Voice.swift.
  setSampleFadeIn(index, sec) {
    const v = this.voices[index]; if (!v?.params) return;
    v.params.sampleFadeInSec = Math.max(0, Math.min(10, sec));
  }
  setSampleFadeOut(index, sec) {
    const v = this.voices[index]; if (!v?.params) return;
    v.params.sampleFadeOutSec = Math.max(0, Math.min(10, sec));
  }

  /// Clear the loaded sample.
  clearSample(index) {
    const v = this.voices[index]; if (!v) return;
    if (v.sampleSrc) {
      try { v.sampleSrc.stop(); } catch {}
      try { v.sampleSrc.disconnect(); } catch {}
      v.sampleSrc = null;
    }
    v.sampleBuffer = null;
  }

  setMute(index, muted) {
    const v = this.voices[index]; if (!v) return;
    v.params.muted = muted;
    this.applySoloMuteLogic();
  }

  setSolo(index, soloed) {
    const v = this.voices[index]; if (!v) return;
    v.params.soloed = soloed;
    this.applySoloMuteLogic();
  }

  setMasterVolume(v) {
    this.masterTarget = v;
    if (!this.ctx) return;
    const t = this.ctx.currentTime;
    this.master.gain.cancelScheduledValues(t);
    this.master.gain.setValueAtTime(this.master.gain.value, t);
    this.master.gain.linearRampToValueAtTime(v, t + RAMP_TIME);
  }

  // v1.1: ensure 5 LFOs exist on the voice before writing. Old
  // presets / state coming from v1.0 .dronepreset files have only
  // 4 entries; the 5th LFO is the new grain / delay / reverb
  // modulator. Pads with a silent default (depth 0 + grainDensity
  // target) so the audible state stays identical until the user
  // dials it up. Also accepts `_lfoPhase` and `_lfoHold` ring
  // buffers being shorter than 5; pads those too.
  _padLfos(v) {
    while (v.params.lfos.length < 5) {
      v.params.lfos.push({ shape: "sine", targets: ["grainDensity"], rateHz: 0.30, depth: 0 });
    }
    if (v._lfoPhase && v._lfoPhase.length < 5) {
      while (v._lfoPhase.length < 5) v._lfoPhase.push(0);
    }
    if (v._lfoHold && v._lfoHold.length < 5) {
      while (v._lfoHold.length < 5) v._lfoHold.push(0);
    }
  }

  setLfoRate(voiceIndex, lfoIndex, rateHz) {
    const v = this.voices[voiceIndex]; if (!v) return;
    this._padLfos(v);
    v.params.lfos[lfoIndex].rateHz = rateHz;
  }

  setLfoDepth(voiceIndex, lfoIndex, depth) {
    const v = this.voices[voiceIndex]; if (!v) return;
    this._padLfos(v);
    v.params.lfos[lfoIndex].depth = depth;
  }

  setLfoShape(voiceIndex, lfoIndex, shape) {
    const v = this.voices[voiceIndex]; if (!v) return;
    this._padLfos(v);
    v.params.lfos[lfoIndex].shape = shape;
  }

  setLfoTarget(voiceIndex, lfoIndex, target) {
    this.setLfoTargets(voiceIndex, lfoIndex, [target]);
  }

  /// v1.1 multi-target: replace the full targets array in one call.
  setLfoTargets(voiceIndex, lfoIndex, targets) {
    const v = this.voices[voiceIndex]; if (!v) return;
    this._padLfos(v);
    v.params.lfos[lfoIndex].targets = Array.isArray(targets) ? targets : [targets];
    delete v.params.lfos[lfoIndex].target;
  }

  setFilterType(voiceIndex, type) {
    const v = this.voices[voiceIndex]; if (!v) return;
    v.params.filter.type = type;
    if (this.ctx) v.filter.type = type;
  }

  setFilterCutoff(voiceIndex, hz) {
    const v = this.voices[voiceIndex]; if (!v) return;
    v.params.filter.cutoffHz = hz;
    if (!this.ctx) return;
    const t = this.ctx.currentTime;
    v.filter.frequency.cancelScheduledValues(t);
    v.filter.frequency.setValueAtTime(v.filter.frequency.value, t);
    v.filter.frequency.linearRampToValueAtTime(hz, t + RAMP_TIME);
  }

  setFilterQ(voiceIndex, q) {
    const v = this.voices[voiceIndex]; if (!v) return;
    v.params.filter.q = q;
    if (!this.ctx) return;
    const t = this.ctx.currentTime;
    v.filter.Q.cancelScheduledValues(t);
    v.filter.Q.setValueAtTime(v.filter.Q.value, t);
    v.filter.Q.linearRampToValueAtTime(q, t + RAMP_TIME);
  }

  // ─── Chorus ───────────────────────────────────────────
  setChorusRate(voiceIndex, rateHz) {
    const v = this.voices[voiceIndex]; if (!v) return;
    v.params.chorus.rateHz = rateHz;
    if (!this.ctx) return;
    const t = this.ctx.currentTime;
    for (const lfo of [v.chLfoL, v.chLfoR]) {
      lfo.frequency.cancelScheduledValues(t);
      lfo.frequency.setValueAtTime(lfo.frequency.value, t);
      lfo.frequency.linearRampToValueAtTime(rateHz, t + RAMP_TIME);
    }
  }
  setChorusDepth(voiceIndex, depth) {
    const v = this.voices[voiceIndex]; if (!v) return;
    v.params.chorus.depth = depth;
    if (!this.ctx) return;
    const t = this.ctx.currentTime;
    const swing = depth * v.chorusMaxSwing;
    for (const g of [v.chLfoLGain, v.chLfoRGain]) {
      g.gain.cancelScheduledValues(t);
      g.gain.setValueAtTime(g.gain.value, t);
      g.gain.linearRampToValueAtTime(swing, t + RAMP_TIME);
    }
  }
  setChorusWidth(voiceIndex, width) {
    const v = this.voices[voiceIndex]; if (!v) return;
    v.params.chorus.width = width;
    // Width is realized as an LFO phase offset; we can't change phase live
    // without restarting the LFO. To stay glitch-free, we approximate width
    // changes by adjusting the *right* LFO's frequency briefly so it drifts
    // into the new phase offset, then snap it back. For simplicity (and to
    // avoid clicks), we leave the phase offset fixed at start time — width
    // updates take full effect on the next play start.
    // No-op at runtime is fine; the value is preserved in state and used by
    // the next ensureStarted() call's chLfoL.start delay.
  }
  setChorusMix(voiceIndex, mix) {
    const v = this.voices[voiceIndex]; if (!v) return;
    v.params.chorus.mix = mix;
    if (!this.ctx) return;
    const t = this.ctx.currentTime;
    const ramp = (g, val) => {
      g.gain.cancelScheduledValues(t);
      g.gain.setValueAtTime(g.gain.value, t);
      g.gain.linearRampToValueAtTime(val, t + RAMP_TIME);
    };
    ramp(v.chorusDry,  1.0 - mix);
    ramp(v.chorusWetL, mix);
    ramp(v.chorusWetR, mix);
  }

  // ─── FM (cross-osc) ───────────────────────────────────
  // sourceIndex: -1 disables; otherwise must differ from voiceIndex.
  setFMSource(voiceIndex, sourceIndex) {
    const v = this.voices[voiceIndex]; if (!v) return;
    if (sourceIndex === voiceIndex) sourceIndex = -1;
    v.params.fm.sourceIndex = sourceIndex;
    this._applyFMPatch(voiceIndex, sourceIndex, v.params.fm.index || 0);
  }
  setFMIndex(voiceIndex, idx) {
    const v = this.voices[voiceIndex]; if (!v) return;
    v.params.fm.index = idx;
    if (v.fmDepthGain && this.ctx) {
      const t = this.ctx.currentTime;
      v.fmDepthGain.gain.cancelScheduledValues(t);
      v.fmDepthGain.gain.setValueAtTime(v.fmDepthGain.gain.value, t);
      v.fmDepthGain.gain.linearRampToValueAtTime(idx, t + RAMP_TIME);
    }
  }
  /// Disconnect any existing FM patch on this voice, then (if sourceIndex
  /// is valid) wire `modulatorVoice.osc → newDepthGain → carrier.fmInput`
  /// with the gain ramping from 0 to the target index over RAMP_TIME so
  /// patch swaps don't click.
  _applyFMPatch(carrierIndex, sourceIndex, depthHz) {
    const carrier = this.voices[carrierIndex]; if (!carrier || !this.ctx) return;
    // Tear down old patch
    if (carrier.fmDepthGain) {
      try { carrier.fmDepthGain.disconnect(); } catch {}
      carrier.fmDepthGain = null;
    }
    carrier.fmSourceIndex = sourceIndex;
    if (sourceIndex < 0 || sourceIndex >= this.voices.length || sourceIndex === carrierIndex) return;
    const modulator = this.voices[sourceIndex];
    if (!modulator || !modulator.osc) return;
    const g = this.ctx.createGain();
    g.gain.value = 0;
    // Tap from the modulator's RAW osc so muting the modulator voice doesn't
    // kill the FM effect — users usually want to hear ONE voice with the
    // other shaping it timbrally.
    modulator.osc.connect(g);
    g.connect(carrier.fmInput);
    carrier.fmDepthGain = g;
    const t = this.ctx.currentTime;
    g.gain.linearRampToValueAtTime(depthHz, t + RAMP_TIME);
  }

  setReverbDecay(voiceIndex, sec) {
    const v = this.voices[voiceIndex]; if (!v) return;
    v.params.reverb.decaySec = sec;
    if (this.ctx) v.reverb.buffer = buildReverbIR(this.ctx, sec);
  }
  setReverbMix(voiceIndex, mix) {
    const v = this.voices[voiceIndex]; if (!v) return;
    v.params.reverb.mix = mix;
    if (!this.ctx) return;
    const t = this.ctx.currentTime;
    v.reverbWet.gain.cancelScheduledValues(t);
    v.reverbWet.gain.setValueAtTime(v.reverbWet.gain.value, t);
    v.reverbWet.gain.linearRampToValueAtTime(mix, t + RAMP_TIME);
  }
  setDelayTime(voiceIndex, sec) {
    const v = this.voices[voiceIndex]; if (!v) return;
    v.params.delay.timeSec = sec;
    if (!this.ctx) return;
    const t = this.ctx.currentTime;
    for (const dn of [v.delayL, v.delayR]) {
      dn.delayTime.cancelScheduledValues(t);
      dn.delayTime.setValueAtTime(dn.delayTime.value, t);
      dn.delayTime.linearRampToValueAtTime(sec, t + RAMP_TIME);
    }
  }
  setDelayFeedback(voiceIndex, fb) {
    const v = this.voices[voiceIndex]; if (!v) return;
    v.params.delay.feedback = fb;
    if (!this.ctx) return;
    // Re-apply mode so feedback gains pick up the new value.
    this._applyDelayMode(voiceIndex, v.params.delay.mode || "mono", v.params.delay.mix, fb);
  }
  setDelayMix(voiceIndex, mix) {
    const v = this.voices[voiceIndex]; if (!v) return;
    v.params.delay.mix = mix;
    if (!this.ctx) return;
    this._applyDelayMode(voiceIndex, v.params.delay.mode || "mono", mix, v.params.delay.feedback);
  }
  setDelayMode(voiceIndex, mode) {
    const v = this.voices[voiceIndex]; if (!v) return;
    v.params.delay.mode = mode;
    if (!this.ctx) return;
    this._applyDelayMode(voiceIndex, mode, v.params.delay.mix, v.params.delay.feedback);
  }
  /// Map (mode, mix, fb) to the seven routing gains. Mono = single tap
  /// centered. Stereo = both delays sound, slight detune happens via timing
  /// dropdown (we keep delay times equal here; future: per-channel offset).
  /// Ping-Pong = cross feedback only, bouncing each tap L↔R.
  _applyDelayMode(voiceIndex, mode, mix, fb) {
    const v = this.voices[voiceIndex]; if (!v || !this.ctx) return;
    const t = this.ctx.currentTime;
    const ramp = (g, val) => {
      g.gain.cancelScheduledValues(t);
      g.gain.setValueAtTime(g.gain.value, t);
      g.gain.linearRampToValueAtTime(val, t + RAMP_TIME);
    };
    let inR = 0, selfL = 0, selfR = 0, crossLR = 0, crossRL = 0,
        wL2L = 0, wL2R = 0, wR2R = 0;
    if (mode === "stereo") {
      inR = 1;  selfL = fb; selfR = fb;
      wL2L = mix; wR2R = mix;
    } else if (mode === "pingPong") {
      // Source only feeds L; L → R cross-feedback creates the bounce; R → L cross-feedback continues it.
      inR = 0;  selfL = 0;  selfR = 0;
      crossLR = fb; crossRL = fb;
      wL2L = mix; wR2R = mix;
    } else {
      // mono — single tap centered: output L on both channels of the merger.
      inR = 0;  selfL = fb; selfR = 0;
      wL2L = mix; wL2R = mix;
    }
    ramp(v.delayInR, inR);
    ramp(v.fbSelfL, selfL); ramp(v.fbSelfR, selfR);
    ramp(v.fbCrossLR, crossLR); ramp(v.fbCrossRL, crossRL);
    ramp(v.wetL2L, wL2L); ramp(v.wetL2R, wL2R); ramp(v.wetR2R, wR2R);
  }

  // ───── solo / mute resolution ─────────────────────────────

  applySoloMuteLogic() {
    const anySoloed = this.voices.some((v) => v.params.soloed);
    for (let i = 0; i < this.voices.length; i++) {
      const v = this.voices[i];
      const audible = (anySoloed ? v.params.soloed : true) && !v.params.muted;
      v._audible = audible;
      this.applyVoiceGain(i);
    }
  }

  applyVoiceGain(index) {
    const v = this.voices[index]; if (!v || !this.ctx) return;
    const target = v._audible === false ? 0 : v.params.amp;
    const t = this.ctx.currentTime;
    v.gain.gain.cancelScheduledValues(t);
    v.gain.gain.setValueAtTime(v.gain.gain.value, t);
    v.gain.gain.linearRampToValueAtTime(target, t + RAMP_TIME);
  }
}

/**
 * Synthesize a stereo impulse response for a reverb of the given decay (seconds).
 * Exponentially-decaying white noise — cheap and musically plausible.
 */
function buildReverbIR(ctx, decaySec) {
  const sec = Math.max(0.05, Math.min(10, decaySec));
  const len = Math.max(1, Math.floor(ctx.sampleRate * sec));
  const ir = ctx.createBuffer(2, len, ctx.sampleRate);
  for (let ch = 0; ch < 2; ch++) {
    const data = ir.getChannelData(ch);
    for (let i = 0; i < len; i++) {
      const env = Math.pow(1 - i / len, 2);
      data[i] = (Math.random() * 2 - 1) * env;
    }
  }
  return ir;
}
