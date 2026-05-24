// Canvas backdrops — blob field (2D Canvas) + Chladni nodal pattern (WebGL).
//
// The Chladni overlay used to be a coarse Canvas grid (160×160 fillRect cells)
// which looked pixelated and forced a tradeoff between detail and CPU. A
// fragment shader evaluating the field at every pixel removes both problems:
// modes can run as high as we want, and output is smooth at native DPR.

import { frequencyHue } from "./music.js";

let bgCanvas, chladniCanvas, bgCtx;
let gl;                  // WebGL context for chladniCanvas (no 2D fallback used)
let glProgram, glAttribs = {}, glUniforms = {};
let getState;
let getEngine;           // optional — returns AudioEngine for live (pitch-LFO-modulated) freqs
let isShowingChladni = true;
let lastSize = { w: 0, h: 0, dpr: 1 };

const VS = `
attribute vec2 a_position;
varying vec2 v_uv;
void main() {
  v_uv = a_position * 0.5 + 0.5;
  gl_Position = vec4(a_position, 0.0, 1.0);
}
`;

const FS = `
precision highp float;
varying vec2 v_uv;
uniform int  u_voiceCount;
uniform vec3 u_modes[4];   // x=m, y=n, z=weight
uniform vec3 u_colors[4];  // rgb 0..1

void main() {
  float field = 0.0;
  vec3  colorAccum = vec3(0.0);
  float weightAccum = 0.0;

  // Constant index loop required by WebGL 1; mask via uniform count.
  for (int i = 0; i < 4; i++) {
    if (i >= u_voiceCount) break;
    float m = u_modes[i].x;
    float n = u_modes[i].y;
    float w = u_modes[i].z;
    float term = cos(m * 3.14159265 * v_uv.x) * cos(n * 3.14159265 * v_uv.y)
               - cos(n * 3.14159265 * v_uv.x) * cos(m * 3.14159265 * v_uv.y);
    field += term * w;
    colorAccum += u_colors[i] * w;
    weightAccum += w;
  }

  float mag = abs(field);
  // Tight threshold on |field| -> the nodal lines stand out as thin curves.
  float node = max(0.0, 1.0 - mag * 9.0);
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
  bgCtx = bgCanvas.getContext("2d");
  initWebGL();
  resize();
  window.addEventListener("resize", resize);
  requestAnimationFrame(loop);
}

export function setChladniVisible(visible) {
  isShowingChladni = visible;
  chladniCanvas.style.display = visible ? "" : "none";
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
  glAttribs.position    = gl.getAttribLocation(glProgram, "a_position");
  glUniforms.voiceCount = gl.getUniformLocation(glProgram, "u_voiceCount");
  glUniforms.modes      = gl.getUniformLocation(glProgram, "u_modes");
  glUniforms.colors     = gl.getUniformLocation(glProgram, "u_colors");
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
  for (const c of [bgCanvas, chladniCanvas]) {
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
  requestAnimationFrame(loop);
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

// Distinct n per voice so each voice contributes a different geometry.
const VOICE_N = [8, 12, 16, 20];

function drawChladniGL() {
  const oscs = getState().oscillators;
  const audible = oscs.filter((_, i) => !isVoiceSilenced(i, oscs));

  // Always clear, even when no voices are audible.
  gl.clearColor(0, 0, 0, 0);
  gl.clear(gl.COLOR_BUFFER_BIT);

  if (audible.length === 0) return;

  const count = Math.min(4, audible.length);
  const modes  = new Float32Array(12);
  const colors = new Float32Array(12);

  // Use the engine's live (pitch-LFO-modulated) freq when available, so the
  // pattern morphs in real time as vibrato plays.
  const engine = getEngine ? getEngine() : null;
  const audibleIndices = [];
  oscs.forEach((o, i) => { if (!isVoiceSilenced(i, oscs)) audibleIndices.push(i); });

  for (let i = 0; i < count; i++) {
    const oscIdx = audibleIndices[i];
    const osc = oscs[oscIdx];
    const liveFreq = (engine && engine.voices && engine.voices[oscIdx] && engine.voices[oscIdx]._effectiveFreq)
      ? engine.voices[oscIdx]._effectiveFreq
      : osc.frequencyHz;
    const logF = Math.log2(Math.max(liveFreq, 20));
    const lo = Math.log2(20), hi = Math.log2(2000);
    const tt = (logF - lo) / (hi - lo);
    // m scales with (live) frequency: 6..22. Vibrato visibly shifts the mode
    // numbers up and down within this range.
    const m = Math.max(3, Math.round(6 + tt * 16));
    const n = VOICE_N[i % VOICE_N.length];
    modes[i * 3 + 0] = m;
    modes[i * 3 + 1] = n;
    modes[i * 3 + 2] = osc.amplitude;
    const [r, g, b] = hslToRgb(frequencyHue(liveFreq), 0.30, 0.85);
    colors[i * 3 + 0] = r;
    colors[i * 3 + 1] = g;
    colors[i * 3 + 2] = b;
  }

  gl.useProgram(glProgram);
  gl.uniform1i(glUniforms.voiceCount, count);
  gl.uniform3fv(glUniforms.modes, modes);
  gl.uniform3fv(glUniforms.colors, colors);
  gl.enableVertexAttribArray(glAttribs.position);
  gl.vertexAttribPointer(glAttribs.position, 2, gl.FLOAT, false, 0, 0);
  gl.drawArrays(gl.TRIANGLE_STRIP, 0, 4);
}

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
