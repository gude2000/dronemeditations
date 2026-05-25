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
      const filter = this.ctx.createBiquadFilter();
      // Reverb (ConvolverNode + wet-gain) and Delay.
      //
      // Delay supports three modes (mono / stereo / ping-pong) via two
      // DelayNodes plus four routing-gain nodes that enable or silence
      // the various feedback edges. Wet is sent through a ChannelMerger
      // so we have proper L/R stereo separation independent of the dry
      // path's StereoPanner.
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

      const synthWaveform = v.waveform === "sample" ? "sine" : v.waveform;
      osc.type = synthWaveform;
      osc.frequency.value = v.frequencyHz;

      const f = v.filter || { type: "lowpass", cutoffHz: 4000, q: 0.7 };
      filter.type = f.type;
      filter.frequency.value = f.cutoffHz;
      filter.Q.value = f.q;

      pan.pan.value = v.pan;
      gain.gain.value = 0;  // fade in via setVoiceState

      // Crossfade: when waveform === "sample", oscGain → 0, sampleGain → 1.
      const isSample = v.waveform === "sample";
      oscGain.gain.value = isSample ? 0 : 1;
      sampleGain.gain.value = isSample ? 1 : 0;

      // Initial FX values from state (or defaults).
      const r = v.reverb || { decaySec: 2.0, mix: 0 };
      const d = v.delay  || { timeSec: 0.30, feedback: 0.40, mix: 0, mode: "mono", timing: "free" };
      reverb.buffer = buildReverbIR(this.ctx, r.decaySec);
      reverbWet.gain.value = r.mix;
      delayL.delayTime.value = d.timeSec;
      delayR.delayTime.value = d.timeSec;

      // Routing:
      //   osc/sample → filter
      //              ─┬→ pan          (dry)
      //               ├→ reverb → reverbWet → pan
      //               ├→ delayL ─┐
      //               └→ delayInR → delayR ─┤  (gates differ per mode; see _applyDelayMode)
      //                          ┌────────┘
      //                          └→ merger → gain  (skips pan to keep ping-pong stereo intact)
      osc.connect(oscGain);
      oscGain.connect(filter);
      sampleGain.connect(filter);
      filter.connect(pan);                            // dry
      filter.connect(reverb).connect(reverbWet).connect(pan);   // reverb wet send

      // Delay topology: filter feeds both delays (delayR gated by delayInR
      // gain); each delay's output feeds back into both itself and the
      // other delay via four routing-gain nodes; both outputs land in the
      // merger as a true stereo pair.
      filter.connect(delayL);
      filter.connect(delayInR); delayInR.connect(delayR);

      delayL.connect(fbSelfL);  fbSelfL.connect(delayL);
      delayR.connect(fbSelfR);  fbSelfR.connect(delayR);
      delayL.connect(fbCrossLR); fbCrossLR.connect(delayR);
      delayR.connect(fbCrossRL); fbCrossRL.connect(delayL);

      delayL.connect(wetL2L); wetL2L.connect(delayMerger, 0, 0);
      delayL.connect(wetL2R); wetL2R.connect(delayMerger, 0, 1);
      delayR.connect(wetR2R); wetR2R.connect(delayMerger, 0, 1);
      delayMerger.connect(gain);

      pan.connect(gain);
      gain.connect(this.master);
      osc.start();

      // Apply the saved mode and the saved mix to the routing gains.
      // Default mode is "mono" when nothing was saved.
      const voiceObj = {
        osc, oscGain, sampleGain, filter, pan, gain,
        reverb, reverbWet,
        delayL, delayR, delayInR,
        fbSelfL, fbSelfR, fbCrossLR, fbCrossRL,
        wetL2L, wetL2R, wetR2R, delayMerger,
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
          reverb: { ...r },
          delay: { ...d },
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
    }
  };

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

    // Crossfade between synth-osc bus and sample bus.
    const oscTarget = waveform === "sample" ? 0 : 1;
    const sampTarget = waveform === "sample" ? 1 : 0;
    v.oscGain.gain.cancelScheduledValues(t);
    v.oscGain.gain.setValueAtTime(v.oscGain.gain.value, t);
    v.oscGain.gain.linearRampToValueAtTime(oscTarget, t + 0.020);
    v.sampleGain.gain.cancelScheduledValues(t);
    v.sampleGain.gain.setValueAtTime(v.sampleGain.gain.value, t);
    v.sampleGain.gain.linearRampToValueAtTime(sampTarget, t + 0.020);

    if (waveform !== "sample") {
      // Brief dip on the master gain to hide the synth osc's phase-reset click.
      const target = v.gain.gain.value;
      v.gain.gain.cancelScheduledValues(t);
      v.gain.gain.setValueAtTime(target, t);
      v.gain.gain.linearRampToValueAtTime(target * 0.5, t + 0.008);
      v.osc.type = waveform;
      v.gain.gain.linearRampToValueAtTime(target, t + 0.024);
    }
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
