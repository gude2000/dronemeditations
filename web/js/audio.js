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
      const sampleGain = this.ctx.createGain();
      // Noise bus — a looping AudioBufferSourceNode fed by either the
      // engine's shared white-noise or pink-noise buffer. We swap which
      // buffer it points to when the waveform changes between the two,
      // and crossfade the noiseGain against oscGain/sampleGain so the
      // active source has the only audible level.
      const noiseGain = this.ctx.createGain();
      noiseGain.gain.value = 0;
      const noiseSrc = this.ctx.createBufferSource();
      noiseSrc.buffer = (v.waveform === "pinkNoise")
        ? this._pinkNoiseBuffer()
        : this._whiteNoiseBuffer();
      noiseSrc.loop = true;
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
      const isNoise  = (v.waveform === "whiteNoise" || v.waveform === "pinkNoise");
      const isOsc    = !isSample && !isNoise;
      oscGain.gain.value    = isOsc    ? 1 : 0;
      sampleGain.gain.value = isSample ? 1 : 0;
      noiseGain.gain.value  = isNoise  ? 1 : 0;

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
      noiseGain.connect(drive);
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
        osc, oscGain, sampleGain, noiseSrc, noiseGain, drive, fmInput, filter, pan, gain, envelopeGain,
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
          lfos: (v.lfos || [
            { shape: "sine", target: "pan",    rateHz: 0.25, depth: 0 },
            { shape: "sh",   target: "amp",    rateHz: 0.50, depth: 0 },
            { shape: "sine", target: "cutoff", rateHz: 0.30, depth: 0 },
            { shape: "sine", target: "pitch",  rateHz: 0.30, depth: 0 }
          ]).map((l) => ({ ...l }))
        },
        _lfoPhase: [0, 0, 0, 0],
        _lfoHold: [0, 0, 0, 0],
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
    }
  };

  /// Per-voice timing envelope, driven by transportElapsed:
  ///   t < startDelay                          → silent
  ///   startDelay <= t < startDelay + FADE    → fade in
  ///   ...full...
  ///   if playDuration > 0 and (t - startDelay) > playDuration
  ///                                          → fade out then silent
  /// FADE is 8 seconds either side — long enough to feel meditative,
  /// short enough not to compete with the user's session timer.
  _applyTimingEnvelope(i, nowAudioTime) {
    const v = this.voices[i]; if (!v || !v.envelopeGain) return;
    const startDelay = v.params.startDelaySec || 0;
    const playDur    = v.params.playDurationSec || 0;
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
    const FADE = 8.0;  // seconds of fade-in and fade-out
    let target = 1.0;
    if (!isFinite(elapsed)) {
      // Transport stopped/paused — leave whatever was there. The master
      // fadeOut covers actual silence; we don't fight it here.
      return;
    } else if (elapsed < startDelay) {
      target = 0;
    } else if (elapsed < startDelay + FADE) {
      target = (elapsed - startDelay) / FADE;
    } else if (playDur > 0 && elapsed >= startDelay + playDur) {
      const fadeOutElapsed = elapsed - (startDelay + playDur);
      target = fadeOutElapsed >= FADE ? 0 : 1 - (fadeOutElapsed / FADE);
    } else {
      target = 1;
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
    let anyPan = false, anyAmp = false, anyCutoff = false, anyPitch = false;

    for (let k = 0; k < 4; k++) {
      const lfo = v.params.lfos[k];
      if (lfo.depth < 0.001) continue;

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
      } else {
        // sample-and-hold
        if (stepped || v._lfoHold[k] == null || v._lfoHold[k] === 0) {
          v._lfoHold[k] = Math.random() * 2 - 1;
        }
        lfoValue = v._lfoHold[k];
      }

      if (lfo.target === "pan") {
        panMod += lfo.depth * lfoValue;
        anyPan = true;
      } else if (lfo.target === "amp") {
        // Tremolo: ±60% swing at depth=1, multiplicative.
        ampScale *= (1 + 0.6 * lfo.depth * lfoValue);
        anyAmp = true;
      } else if (lfo.target === "cutoff") {
        // ±2 octaves swing at depth=1.
        cutoffOct += 2 * lfo.depth * lfoValue;
        anyCutoff = true;
      } else if (lfo.target === "pitch") {
        // ±2 semitones swing at depth=1 (musical vibrato range).
        pitchSemitones += 2 * lfo.depth * lfoValue;
        anyPitch = true;
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
    if (anyPitch) {
      const pitchMult = Math.pow(2, pitchSemitones / 12);
      // Apply to synth oscillator frequency.
      const freqEff = Math.max(0.01, v.params.freq * pitchMult);
      v.osc.frequency.cancelScheduledValues(now);
      v.osc.frequency.setValueAtTime(v.osc.frequency.value, now);
      v.osc.frequency.linearRampToValueAtTime(freqEff, now + LFO_SMOOTH);
      // Apply to sample playback rate too, so loaded samples vibrato along.
      if (v.sampleSrc) {
        const rateBase = Math.max(0.05, Math.min(20, v.params.freq / 220));
        const rateEff = Math.max(0.05, Math.min(20, rateBase * pitchMult));
        v.sampleSrc.playbackRate.cancelScheduledValues(now);
        v.sampleSrc.playbackRate.setValueAtTime(v.sampleSrc.playbackRate.value, now);
        v.sampleSrc.playbackRate.linearRampToValueAtTime(rateEff, now + LFO_SMOOTH);
      }
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
    // When a sample is loaded, freq acts as the pitch shifter (220 Hz = unity).
    if (v.sampleSrc) {
      const rate = Math.max(0.05, Math.min(20, hz / 220));
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
    v.params.waveform = waveform;
    if (!this.ctx) return;
    const t = this.ctx.currentTime;

    // Three-way crossfade across osc / sample / noise so exactly one source
    // is audible at a time.
    const isSample = waveform === "sample";
    const isNoise  = (waveform === "whiteNoise" || waveform === "pinkNoise");
    const isOsc    = !isSample && !isNoise;
    const ramp = (param, target) => {
      param.cancelScheduledValues(t);
      param.setValueAtTime(param.value, t);
      param.linearRampToValueAtTime(target, t + 0.020);
    };
    ramp(v.oscGain.gain,    isOsc    ? 1 : 0);
    ramp(v.sampleGain.gain, isSample ? 1 : 0);
    ramp(v.noiseGain.gain,  isNoise  ? 1 : 0);

    // For noise: swap the buffer between white and pink if the active type
    // changed. AudioBufferSourceNode lets you only set buffer once OR while
    // not started — so we hot-swap by stopping + recreating the source.
    if (isNoise) {
      const wantBuffer = (waveform === "pinkNoise")
        ? this._pinkNoiseBuffer()
        : this._whiteNoiseBuffer();
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
    src.loopStart = 0;
    src.loopEnd = audioBuffer.duration;
    src.playbackRate.value = Math.max(0.05, Math.min(20, v.params.freq / 220));
    src.connect(v.sampleGain);
    src.start();
    v.sampleSrc = src;
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

  setLfoRate(voiceIndex, lfoIndex, rateHz) {
    const v = this.voices[voiceIndex]; if (!v) return;
    v.params.lfos[lfoIndex].rateHz = rateHz;
  }

  setLfoDepth(voiceIndex, lfoIndex, depth) {
    const v = this.voices[voiceIndex]; if (!v) return;
    v.params.lfos[lfoIndex].depth = depth;
  }

  setLfoShape(voiceIndex, lfoIndex, shape) {
    const v = this.voices[voiceIndex]; if (!v) return;
    v.params.lfos[lfoIndex].shape = shape;
  }

  setLfoTarget(voiceIndex, lfoIndex, target) {
    const v = this.voices[voiceIndex]; if (!v) return;
    v.params.lfos[lfoIndex].target = target;
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
