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
const RMS_FLOOR = 0.005;     // below this the buffer is treated as silence
const PEAK_THRESH = 0.85;    // autocorrelation peak must be ≥ this fraction
                              // of best-found peak for confident detection

let micStream = null;
let micCtx = null;
let analyser = null;
let buf = null;
let rafId = null;

export async function startListening(onPitch) {
  if (micStream) return;
  micStream = await navigator.mediaDevices.getUserMedia({
    audio: {
      echoCancellation: false,
      noiseSuppression: false,
      autoGainControl: false
    }
  });
  const AC = window.AudioContext || window.webkitAudioContext;
  micCtx = new AC();
  const source = micCtx.createMediaStreamSource(micStream);
  analyser = micCtx.createAnalyser();
  analyser.fftSize = 4096;     // ~93 ms window @ 44.1k — good for low pitches
  buf = new Float32Array(analyser.fftSize);
  source.connect(analyser);
  // (Don't connect analyser to destination — we don't want to hear the mic.)

  const tick = () => {
    rafId = requestAnimationFrame(tick);
    analyser.getFloatTimeDomainData(buf);
    const hz = autocorrelate(buf, micCtx.sampleRate);
    onPitch(hz > 0 ? hz : null);
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

// Autocorrelation via the standard "peak picking with parabolic
// interpolation" approach. Fast enough to run every frame on a 4k window.
function autocorrelate(buf, sampleRate) {
  const N = buf.length;

  // Bail early on silence.
  let rms = 0;
  for (let i = 0; i < N; i++) rms += buf[i] * buf[i];
  rms = Math.sqrt(rms / N);
  if (rms < RMS_FLOOR) return -1;

  const minLag = Math.floor(sampleRate / MAX_FREQ);
  const maxLag = Math.min(N - 1, Math.floor(sampleRate / MIN_FREQ));

  // Trim ends to avoid the autocorrelation's natural taper.
  let bestLag = -1;
  let bestCorr = 0;
  let foundPositive = false;
  for (let lag = minLag; lag <= maxLag; lag++) {
    let corr = 0;
    for (let i = 0; i < N - lag; i++) corr += buf[i] * buf[i + lag];
    corr /= (N - lag);
    if (corr > 0) foundPositive = true;
    // Find first peak that crosses PEAK_THRESH × bestCorr — that's the
    // fundamental, not a higher harmonic.
    if (corr > bestCorr) {
      bestCorr = corr;
      bestLag = lag;
    } else if (foundPositive && corr < bestCorr * PEAK_THRESH && bestLag > 0) {
      break;
    }
  }
  if (bestLag < 0 || bestCorr < 0.01) return -1;

  // Parabolic interpolation for sub-sample lag accuracy.
  let refinedLag = bestLag;
  if (bestLag > 0 && bestLag < N - 1) {
    let y0 = 0, y1 = 0, y2 = 0;
    for (let i = 0; i < N - bestLag - 1; i++) {
      y0 += buf[i] * buf[i + bestLag - 1];
      y1 += buf[i] * buf[i + bestLag];
      y2 += buf[i] * buf[i + bestLag + 1];
    }
    y0 /= (N - bestLag - 1);
    y1 /= (N - bestLag - 1);
    y2 /= (N - bestLag - 1);
    const denom = (y0 - 2 * y1 + y2);
    if (Math.abs(denom) > 1e-9) {
      refinedLag = bestLag + 0.5 * (y0 - y2) / denom;
    }
  }
  return sampleRate / refinedLag;
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
