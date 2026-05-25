// Microphone pitch detection — "tune to room/voice."
//
// Pulls audio from getUserMedia, runs autocorrelation on each frame's
// time-domain buffer, and returns the dominant pitch in Hz. Search range
// is ~80–2000 Hz (covers male/female voice + most pitched ambient sources).
//
// Caller drives lifecycle: call start(onPitch) to begin, stop() to release
// the mic. onPitch fires every animation frame with either a number (Hz)
// or null when no stable pitch is detected (signal too quiet or aperiodic).

const MIN_FREQ = 70;
const MAX_FREQ = 2000;
const RMS_FLOOR = 0.002;     // dropped from 0.005 so quiet/whispered sounds
                              // still register the autocorrelation pass
const PEAK_THRESH = 0.85;    // autocorrelation peak must be ≥ this fraction
                              // of best-found peak for confident detection

let micStream = null;
let micCtx = null;
let analyser = null;
let buf = null;
let rafId = null;

/**
 * Start listening on the default microphone. `onUpdate` fires every animation
 * frame with `{ hz, level }` where hz is detected pitch (or null when no
 * stable pitch) and level is the buffer RMS [0..1] for a live audio-level
 * indicator so the user can see the mic is alive even before a pitch lands.
 */
export async function startListening(onUpdate, deviceId = null) {
  if (micStream) return;
  const audioConstraints = {
    echoCancellation: false,
    noiseSuppression: false,
    autoGainControl: false
  };
  if (deviceId) audioConstraints.deviceId = { exact: deviceId };
  micStream = await navigator.mediaDevices.getUserMedia({ audio: audioConstraints });
  const AC = window.AudioContext || window.webkitAudioContext;
  micCtx = new AC();
  // Critical: AudioContext often spawns suspended in modern browsers
  // (Chrome/Safari autoplay policy). Without resume() the AnalyserNode
  // never receives data → pitch detection silently fails.
  if (micCtx.state === "suspended") {
    try { await micCtx.resume(); } catch {}
  }
  const source = micCtx.createMediaStreamSource(micStream);
  analyser = micCtx.createAnalyser();
  analyser.fftSize = 4096;     // ~93 ms window @ 44.1k — good for low pitches
  analyser.smoothingTimeConstant = 0;  // we want raw time-domain data
  buf = new Float32Array(analyser.fftSize);
  source.connect(analyser);
  // (Don't connect analyser to destination — we don't want to hear the mic.)

  const tick = () => {
    rafId = requestAnimationFrame(tick);
    analyser.getFloatTimeDomainData(buf);
    // RMS for the live level meter — always emit so UI can show activity
    // even when no clean pitch can be extracted.
    let sumSq = 0;
    for (let i = 0; i < buf.length; i++) sumSq += buf[i] * buf[i];
    const rms = Math.sqrt(sumSq / buf.length);
    const hz = autocorrelate(buf, micCtx.sampleRate);
    onUpdate({ hz: hz > 0 ? hz : null, level: rms });
  };
  tick();
}

export function stopListening() {
  if (rafId) cancelAnimationFrame(rafId);
  rafId = null;
  if (micStream) micStream.getTracks().forEach((t) => t.stop());
  micStream = null;
  if (micCtx) micCtx.close().catch(() => {});
  micCtx = null;
  analyser = null;
  buf = null;
}

export function isListening() {
  return micStream !== null;
}

// YIN pitch detector (de Cheveigné & Kawahara, 2002). Far more robust against
// the octave-error bug the plain autocorrelation algorithm had — the previous
// implementation could lock onto the early descent from lag=0 and then let
// parabolic interpolation push the refined lag below the search range, which
// is how a hummed D#4 was occasionally reported as D#10.
//
// Algorithm:
//   1. Difference function  d[lag] = Σ (x[i] - x[i+lag])²
//   2. Cumulative mean normalized difference function (CMNDF):
//      d'[lag] = d[lag] · lag / Σ(d[1..lag])
//   3. First lag past minLag where d'[lag] drops below `threshold`, then
//      walk forward while d' is still decreasing to land in the true local
//      minimum.
//   4. Parabolic interpolation on the CMNDF for sub-sample accuracy.
//   5. Hard clamp to [MIN_FREQ, MAX_FREQ] as defense in depth.
const YIN_THRESHOLD = 0.15;   // YIN paper recommends 0.10–0.15
const YIN_ABSMAX = 0.5;       // reject very weak periodicity

function autocorrelate(buf, sampleRate) {
  const N = buf.length;

  // Bail early on silence.
  let rms = 0;
  for (let i = 0; i < N; i++) rms += buf[i] * buf[i];
  rms = Math.sqrt(rms / N);
  if (rms < RMS_FLOOR) return -1;

  const minLag = Math.max(2, Math.floor(sampleRate / MAX_FREQ));
  const maxLag = Math.min(Math.floor(N / 2), Math.floor(sampleRate / MIN_FREQ));
  if (minLag >= maxLag) return -1;

  // 1. Difference function over a fixed analysis window. Using a window of
  //    size (N - maxLag) keeps every lag's comparison the same length so
  //    d[lag] values are directly comparable.
  const W = N - maxLag;
  const d = new Float32Array(maxLag + 1);
  for (let lag = 1; lag <= maxLag; lag++) {
    let sum = 0;
    for (let i = 0; i < W; i++) {
      const diff = buf[i] - buf[i + lag];
      sum += diff * diff;
    }
    d[lag] = sum;
  }

  // 2. CMNDF — normalizes against the running mean so the function starts
  //    at 1.0 and dips below 1 only where the signal repeats.
  const cmndf = new Float32Array(maxLag + 1);
  cmndf[0] = 1;
  let runningSum = 0;
  for (let lag = 1; lag <= maxLag; lag++) {
    runningSum += d[lag];
    cmndf[lag] = (runningSum > 0) ? d[lag] * lag / runningSum : 1;
  }

  // 3. First lag in [minLag, maxLag) below threshold, then walk to local min.
  let bestLag = -1;
  for (let lag = minLag; lag < maxLag; lag++) {
    if (cmndf[lag] < YIN_THRESHOLD) {
      while (lag + 1 < maxLag && cmndf[lag + 1] < cmndf[lag]) lag++;
      bestLag = lag;
      break;
    }
  }
  if (bestLag < 0) {
    // Fall back to the absolute minimum of CMNDF if no lag crossed threshold.
    let minVal = Infinity;
    for (let lag = minLag; lag < maxLag; lag++) {
      if (cmndf[lag] < minVal) { minVal = cmndf[lag]; bestLag = lag; }
    }
    if (bestLag < 0 || minVal > YIN_ABSMAX) return -1;
  }

  // 4. Parabolic refinement on the CMNDF (concave-up valley).
  let refined = bestLag;
  if (bestLag > minLag && bestLag < maxLag - 1) {
    const y0 = cmndf[bestLag - 1];
    const y1 = cmndf[bestLag];
    const y2 = cmndf[bestLag + 1];
    const denom = (y0 - 2 * y1 + y2);
    if (Math.abs(denom) > 1e-9) {
      const shift = 0.5 * (y0 - y2) / denom;
      // Clamp shift to ±1 sample — anything bigger is a fit failure.
      refined = bestLag + Math.max(-1, Math.min(1, shift));
    }
  }
  // 5. Defense in depth: clamp result so we never report a frequency
  //    outside [MIN_FREQ, MAX_FREQ]. This is what stopped the old
  //    autocorrelation from ever reporting D#10 again — the YIN math
  //    above won't produce it, but the clamp guarantees it can't.
  const hz = sampleRate / refined;
  if (hz < MIN_FREQ || hz > MAX_FREQ) return -1;
  return hz;
}

/**
 * Enumerate available audio input devices. Labels are only populated after
 * the user has granted mic permission at least once in this origin/session,
 * so it's best to call this AFTER startListening() has succeeded once.
 */
export async function listInputDevices() {
  if (!navigator.mediaDevices?.enumerateDevices) return [];
  const all = await navigator.mediaDevices.enumerateDevices();
  return all
    .filter((d) => d.kind === "audioinput")
    .map((d, i) => ({
      deviceId: d.deviceId,
      label: d.label || `Microphone ${i + 1}`
    }));
}

/// Stop and immediately restart the mic stream on a different device.
export async function switchInputDevice(deviceId, onUpdate) {
  stopListening();
  // Brief pause so the previous track has time to release the hardware.
  await new Promise((r) => setTimeout(r, 120));
  await startListening(onUpdate, deviceId);
}

// Convert a frequency to its nearest 12-TET note + cents-off.
export function freqToNote(hz, refA4 = 440) {
  if (!hz || hz <= 0) return null;
  const noteNames = ["C", "C♯", "D", "D♯", "E", "F", "F♯", "G", "G♯", "A", "A♯", "B"];
  const midi = 69 + 12 * Math.log2(hz / refA4);
  const midiRound = Math.round(midi);
  const cents = (midi - midiRound) * 100;
  const noteIdx = ((midiRound % 12) + 12) % 12;
  const octave = Math.floor(midiRound / 12) - 1;
  return {
    name: noteNames[noteIdx],
    octave,
    cents,
    midi: midiRound,
    pitchClassId: noteIdx,    // 0=C, 1=C♯, ..., 9=A, etc.
  };
}
