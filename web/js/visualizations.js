// Canvas backdrops — blob field (2D Canvas) + Chladni nodal pattern (WebGL).
//
// Chladni rendering is calibrated against 17 brusspup demo frames:
//   f(m, n) ≈ 18.6 · (m² + n²)
// Mode pairs come from the eigenmode table in chladni-modes.js; the shader
// crossfades between the two adjacent (m,n) pairs that bracket each voice's
// live frequency, so vibrato breathes between physical modes instead of
// snapping or sliding along arbitrary continuous-m curves.

import { frequencyHue } from "./music.js";
import { modePairForFreq } from "./chladni-modes.js";

let bgCanvas, chladniCanvas, spectrumCanvas, bgCtx, spectrumCtx;
let gl;                  // WebGL context for chladniCanvas (no 2D fallback used)
let glProgram, glAttribs = {}, glUniforms = {};
let getState;
let getEngine;           // optional — returns AudioEngine for live (pitch-LFO-modulated) freqs
let isShowingChladni = true;
let isShowingSpectrum = false;
let spectrumBuf = null;  // Uint8Array for AnalyserNode.getByteFrequencyData
let lastSize = { w: 0, h: 0, dpr: 1 };

const VS = `
attribute vec2 a_position;
varying vec2 v_uv;
void main() {
  v_uv = a_position * 0.5 + 0.5;
  gl_Position = vec4(a_position, 0.0, 1.0);
}
`;

// Up to 8 modes — 4 voices × 2 crossfading eigenmodes per voice.
const FS = `
precision highp float;
varying vec2 v_uv;
uniform int   u_modeCount;
uniform vec3  u_modes[8];   // x=m, y=n, z=weight
uniform vec3  u_colors[8];  // rgb 0..1 (per-mode color carried from voice)
uniform float u_zoom;       // 1.0 = plate fills viewport; >1 zooms in on center

void main() {
  // Apply zoom around plate center. We DON'T clip outside [0,1]² — the
  // Chladni cos math is naturally periodic, so the pattern tiles to fill
  // the viewport at any zoom level (z<1 shows several copies; z>1 zooms
  // into a single copy). User always sees a full-screen pattern.
  vec2 puv = (v_uv - vec2(0.5)) / u_zoom + vec2(0.5);

  float field = 0.0;
  vec3  colorAccum = vec3(0.0);
  float weightAccum = 0.0;

  for (int i = 0; i < 8; i++) {
    if (i >= u_modeCount) break;
    float m = u_modes[i].x;
    float n = u_modes[i].y;
    float w = u_modes[i].z;
    float mPi = m * 3.14159265;
    float nPi = n * 3.14159265;
    // Antisymmetric Chladni formula — calibration table only contains
    // (m, n) pairs with m < n, so the formula never vanishes.
    float term = 0.5 * (cos(mPi * puv.x) * cos(nPi * puv.y)
                      - cos(nPi * puv.x) * cos(mPi * puv.y));
    field += term * w;
    colorAccum += u_colors[i] * w;
    weightAccum += w;
  }

  float mag = abs(field);
  // Tight threshold on |field| -> the nodal lines stand out as thin curves.
  float node = max(0.0, 1.0 - mag * 9.0);

  // Center-driver effect: brusspup's plate is driven by a center bolt, so
  // every real frame shows (a) a small sand pile right on the driver and
  // (b) a thin nodal ring at small radius. Add both regardless of frequency.
  float rCenter = length(puv - vec2(0.5, 0.5));
  float centerBlob = smoothstep(0.025, 0.015, rCenter);
  float centerRing = smoothstep(0.012, 0.0, abs(rCenter - 0.075));
  float centerFeature = max(centerBlob * 0.55, centerRing * 0.75);
  node = max(node, centerFeature);

  if (node <= 0.04) discard;

  vec3 baseColor = weightAccum > 0.0 ? colorAccum / weightAccum : vec3(0.85);
  // Lift toward white so the "sand" reads as bright on dark, not muddy color.
  vec3 finalColor = mix(vec3(0.95), baseColor, 0.30);
  gl_FragColor = vec4(finalColor, node * 0.85);
}
`;

// ──────────────────────────────────────────────────
// Init / lifecycle
// ──────────────────────────────────────────────────

export function initVisualizations(state, engineGetter) {
  getState = state;
  getEngine = engineGetter || null;
  bgCanvas = document.getElementById("bg-canvas");
  chladniCanvas = document.getElementById("chladni-canvas");
  spectrumCanvas = document.getElementById("spectrum-canvas");
  bgCtx = bgCanvas.getContext("2d");
  if (spectrumCanvas) spectrumCtx = spectrumCanvas.getContext("2d");
  initWebGL();
  initZoomControls();
  resize();
  window.addEventListener("resize", resize);
  requestAnimationFrame(loop);
}

export function setChladniVisible(visible) {
  isShowingChladni = visible;
  chladniCanvas.style.display = visible ? "" : "none";
}

export function setSpectrumVisible(visible) {
  isShowingSpectrum = visible;
  if (spectrumCanvas) spectrumCanvas.style.display = visible ? "" : "none";
}

function initWebGL() {
  gl = chladniCanvas.getContext("webgl", {
    premultipliedAlpha: false,
    antialias: true,
    alpha: true
  });
  if (!gl) {
    console.warn("WebGL not available — Chladni overlay disabled.");
    chladniCanvas.style.display = "none";
    return;
  }
  const vs = compileShader(gl.VERTEX_SHADER, VS);
  const fs = compileShader(gl.FRAGMENT_SHADER, FS);
  glProgram = gl.createProgram();
  gl.attachShader(glProgram, vs);
  gl.attachShader(glProgram, fs);
  gl.linkProgram(glProgram);
  if (!gl.getProgramParameter(glProgram, gl.LINK_STATUS)) {
    console.error("Chladni shader link failed:", gl.getProgramInfoLog(glProgram));
    gl = null;
    chladniCanvas.style.display = "none";
    return;
  }
  glAttribs.position   = gl.getAttribLocation(glProgram, "a_position");
  glUniforms.modeCount = gl.getUniformLocation(glProgram, "u_modeCount");
  glUniforms.modes     = gl.getUniformLocation(glProgram, "u_modes");
  glUniforms.colors    = gl.getUniformLocation(glProgram, "u_colors");
  glUniforms.zoom      = gl.getUniformLocation(glProgram, "u_zoom");
  // Fullscreen quad (TRIANGLE_STRIP).
  const buf = gl.createBuffer();
  gl.bindBuffer(gl.ARRAY_BUFFER, buf);
  gl.bufferData(
    gl.ARRAY_BUFFER,
    new Float32Array([-1, -1, 1, -1, -1, 1, 1, 1]),
    gl.STATIC_DRAW
  );
  gl.enable(gl.BLEND);
  gl.blendFunc(gl.SRC_ALPHA, gl.ONE_MINUS_SRC_ALPHA);
}

function compileShader(type, src) {
  const shader = gl.createShader(type);
  gl.shaderSource(shader, src);
  gl.compileShader(shader);
  if (!gl.getShaderParameter(shader, gl.COMPILE_STATUS)) {
    const log = gl.getShaderInfoLog(shader);
    gl.deleteShader(shader);
    throw new Error("Shader compile failed: " + log);
  }
  return shader;
}

function resize() {
  const dpr = Math.min(window.devicePixelRatio || 1, 2);
  const w = window.innerWidth;
  const h = window.innerHeight;
  const canvases = [bgCanvas, chladniCanvas];
  if (spectrumCanvas) canvases.push(spectrumCanvas);
  for (const c of canvases) {
    c.width = Math.round(w * dpr);
    c.height = Math.round(h * dpr);
    c.style.width = w + "px";
    c.style.height = h + "px";
  }
  lastSize = { w, h, dpr };
  if (gl) gl.viewport(0, 0, chladniCanvas.width, chladniCanvas.height);
}

function loop(t) {
  drawBlobs(t / 1000);
  if (isShowingChladni && gl) drawChladniGL();
  if (isShowingSpectrum) drawSpectrum();
  requestAnimationFrame(loop);
}

// Spectrum analyzer — log-frequency bars sourced from the engine's
// AnalyserNode. Skipped entirely when toggled off so the audio
// graph stays cheap.
function drawSpectrum() {
  const engine = getEngine ? getEngine() : null;
  const analyser = engine?.spectrumAnalyser;
  if (!analyser || !spectrumCtx) return;
  if (!spectrumBuf || spectrumBuf.length !== analyser.frequencyBinCount) {
    spectrumBuf = new Uint8Array(analyser.frequencyBinCount);
  }
  analyser.getByteFrequencyData(spectrumBuf);

  const { w, h, dpr } = lastSize;
  spectrumCtx.setTransform(dpr, 0, 0, dpr, 0, 0);
  spectrumCtx.clearRect(0, 0, w, h);

  const sr = engine.ctx?.sampleRate || 48000;
  const nyquist = sr / 2;
  // Show 20 Hz … 16 kHz on a log axis.
  const minHz = 20, maxHz = 16000;
  const logLo = Math.log2(minHz), logHi = Math.log2(maxHz);
  // Bar grid — one bar every ~4 screen pixels so it stays smooth on phones.
  const barW = 4;
  const cols = Math.floor(w / barW);
  for (let i = 0; i < cols; i++) {
    const t = i / (cols - 1);
    const hz = Math.pow(2, logLo + t * (logHi - logLo));
    // Map Hz back to FFT bin.
    const binIdx = Math.min(
      spectrumBuf.length - 1,
      Math.floor((hz / nyquist) * spectrumBuf.length)
    );
    const level = spectrumBuf[binIdx] / 255;  // 0..1
    if (level < 0.02) continue;
    const barH = Math.max(2, level * h * 0.7);
    const y = h - barH;
    // Hue rotates with frequency (low = warm, high = cool); same palette as Chladni.
    const hue = 0.05 + 0.6 * t;
    spectrumCtx.fillStyle = `hsla(${Math.round(hue * 360)}, 70%, 60%, ${0.35 + 0.5 * level})`;
    spectrumCtx.fillRect(i * barW, y, barW - 1, barH);
  }
}

// ──────────────────────────────────────────────────
// Blobs (2D Canvas, unchanged)
// ──────────────────────────────────────────────────
function drawBlobs(t) {
  const { w, h, dpr } = lastSize;
  const ctx = bgCtx;
  ctx.setTransform(dpr, 0, 0, dpr, 0, 0);

  const grd = ctx.createLinearGradient(0, 0, 0, h);
  grd.addColorStop(0, "#040405");
  grd.addColorStop(1, "#0c0c10");
  ctx.fillStyle = grd;
  ctx.fillRect(0, 0, w, h);

  const oscs = getState().oscillators;
  ctx.globalCompositeOperation = "screen";

  for (let i = 0; i < oscs.length; i++) {
    const osc = oscs[i];
    const isAudible = !isVoiceSilenced(i, oscs);
    const logF = Math.log2(Math.max(osc.frequencyHz, 20));
    const speedScale = 1.0 + (logF - Math.log2(20)) / 12;
    const phaseA = i * Math.PI * 0.5;
    const phaseB = i * Math.PI * 0.31;
    const omegaX = 0.045 * speedScale;
    const omegaY = 0.052 * speedScale;
    const nx = (Math.sin(omegaX * t + phaseA) + 0.6 * Math.sin(0.13 * t + phaseB)) / 1.6;
    const ny = (Math.cos(omegaY * t + phaseB) + 0.6 * Math.cos(0.17 * t + phaseA)) / 1.6;

    const cx = (nx * 0.5 + 0.5) * w;
    const cy = (ny * 0.5 + 0.5) * h;
    const maxDim = Math.max(w, h);
    const radius = maxDim * (0.30 + 0.06 * (i % 3));
    const hue = frequencyHue(osc.frequencyHz);
    const alpha = isAudible ? 0.32 : 0.10;
    const color = `hsla(${Math.round(hue * 360)}, 55%, 60%, ${alpha})`;
    const colorFade = `hsla(${Math.round(hue * 360)}, 55%, 60%, 0)`;

    const radial = ctx.createRadialGradient(cx, cy, 1, cx, cy, radius);
    radial.addColorStop(0, color);
    radial.addColorStop(1, colorFade);
    ctx.fillStyle = radial;
    ctx.beginPath();
    ctx.arc(cx, cy, radius, 0, Math.PI * 2);
    ctx.fill();
  }
  ctx.globalCompositeOperation = "source-over";
}

// ──────────────────────────────────────────────────
// Chladni (WebGL fragment shader, smooth at any DPR)
// ──────────────────────────────────────────────────

// Reusable buffers — up to 4 voices × 2 crossfading modes per voice = 8.
const _modesBuf  = new Float32Array(24);
const _colorsBuf = new Float32Array(24);

function drawChladniGL() {
  const oscs = getState().oscillators;
  const audible = oscs.filter((_, i) => !isVoiceSilenced(i, oscs));

  // Always clear, even when no voices are audible.
  gl.clearColor(0, 0, 0, 0);
  gl.clear(gl.COLOR_BUFFER_BIT);

  if (audible.length === 0) return;

  // Use the engine's live (pitch-LFO-modulated) freq when available, so the
  // pattern morphs in real time as vibrato plays.
  const engine = getEngine ? getEngine() : null;
  const audibleIndices = [];
  oscs.forEach((o, i) => { if (!isVoiceSilenced(i, oscs)) audibleIndices.push(i); });

  const voiceCount = Math.min(4, audible.length);
  let modeCount = 0;

  for (let i = 0; i < voiceCount; i++) {
    const oscIdx = audibleIndices[i];
    const osc = oscs[oscIdx];
    const liveFreq = (engine && engine.voices && engine.voices[oscIdx] && engine.voices[oscIdx]._effectiveFreq)
      ? engine.voices[oscIdx]._effectiveFreq
      : osc.frequencyHz;

    const [a, b] = modePairForFreq(liveFreq);
    const [r, g, bcol] = hslToRgb(frequencyHue(liveFreq), 0.30, 0.85);

    // Each voice contributes 2 modes (a and b), scaled by voice amplitude.
    // Skip near-zero weights so we don't burn a uniform slot on nothing.
    for (const mode of [a, b]) {
      if (mode.weight < 0.001 || modeCount >= 8) continue;
      _modesBuf[modeCount * 3 + 0] = mode.m;
      _modesBuf[modeCount * 3 + 1] = mode.n;
      _modesBuf[modeCount * 3 + 2] = mode.weight * osc.amplitude;
      _colorsBuf[modeCount * 3 + 0] = r;
      _colorsBuf[modeCount * 3 + 1] = g;
      _colorsBuf[modeCount * 3 + 2] = bcol;
      modeCount++;
    }
  }

  gl.useProgram(glProgram);
  gl.uniform1i(glUniforms.modeCount, modeCount);
  gl.uniform3fv(glUniforms.modes, _modesBuf);
  gl.uniform3fv(glUniforms.colors, _colorsBuf);
  gl.uniform1f(glUniforms.zoom, zoomLevel);
  gl.enableVertexAttribArray(glAttribs.position);
  gl.vertexAttribPointer(glAttribs.position, 2, gl.FLOAT, false, 0, 0);
  gl.drawArrays(gl.TRIANGLE_STRIP, 0, 4);
}

// ──────────────────────────────────────────────────
// Zoom: ghost slider on left edge + scroll-wheel + localStorage persist
// ──────────────────────────────────────────────────
let zoomLevel = 1.0;
const ZOOM_MIN = 0.25, ZOOM_MAX = 4.0;
let zoomSlider, zoomReadout;

function setZoom(z) {
  zoomLevel = Math.max(ZOOM_MIN, Math.min(ZOOM_MAX, z));
  if (zoomSlider) zoomSlider.value = zoomLevel.toFixed(3);
  if (zoomReadout) zoomReadout.textContent = zoomLevel.toFixed(2) + "×";
  try { localStorage.setItem("chladni-bg-zoom", String(zoomLevel)); } catch {}
}

function initZoomControls() {
  zoomSlider = document.getElementById("zoom-slider");
  zoomReadout = document.getElementById("zoom-readout");
  if (!zoomSlider) return;
  // Restore prior zoom; default 1.0.
  try {
    const saved = parseFloat(localStorage.getItem("chladni-bg-zoom"));
    if (Number.isFinite(saved)) setZoom(saved); else setZoom(1.0);
  } catch { setZoom(1.0); }
  zoomSlider.addEventListener("input", (e) => setZoom(parseFloat(e.target.value)));
  // Scroll-wheel zoom, but skip if hovering over the controls panel so the
  // wheel still scrolls long control lists.
  window.addEventListener("wheel", (e) => {
    if (e.target.closest && e.target.closest("#controls, #zoom-wrap")) return;
    e.preventDefault();
    const factor = Math.exp(-e.deltaY * 0.0015);
    setZoom(zoomLevel * factor);
  }, { passive: false });
}
// Run after DOM is in place — initVisualizations is called on load.

function isVoiceSilenced(i, oscs) {
  const anySoloed = oscs.some((o) => o.isSoloed);
  return (anySoloed && !oscs[i].isSoloed) || oscs[i].isMuted;
}

function hslToRgb(h, s, l) {
  // h in [0, 1)
  const c = (1 - Math.abs(2 * l - 1)) * s;
  const x = c * (1 - Math.abs(((h * 6) % 2) - 1));
  const m = l - c / 2;
  let r, g, b;
  if (h < 1 / 6)      { r = c; g = x; b = 0; }
  else if (h < 2 / 6) { r = x; g = c; b = 0; }
  else if (h < 3 / 6) { r = 0; g = c; b = x; }
  else if (h < 4 / 6) { r = 0; g = x; b = c; }
  else if (h < 5 / 6) { r = x; g = 0; b = c; }
  else                { r = c; g = 0; b = x; }
  return [r + m, g + m, b + m];
}
