// Pop-out Chladni window.
//
// Runs the same WebGL fragment shader as the main app's visualizations.js
// (same physically-calibrated f→(m,n) mapping from chladni-modes.js), plus a
// 3000-grain sand particle simulation on top. Fullscreen, with bidirectional
// state sync to the main window via BroadcastChannel.

import { frequencyHue } from "./music.js";
import { modePairForFreq, chladniField } from "./chladni-modes.js";

const canvas = document.getElementById("chladni");
const disconnected = document.getElementById("disconnected");
let gl;
let glProgram, glAttribs = {}, glUniforms = {};

const VS = `
attribute vec2 a_position;
varying vec2 v_uv;
void main() {
  v_uv = a_position * 0.5 + 0.5;
  gl_Position = vec4(a_position, 0.0, 1.0);
}
`;

// Up to 8 modes — 4 voices × 2 crossfading eigenmodes per voice. Same
// math as visualizations.js so the pop-out looks identical to the main app.
const FS = `
precision highp float;
varying vec2 v_uv;
uniform int   u_modeCount;
uniform vec3  u_modes[8];
uniform vec3  u_colors[8];
uniform float u_zoom;       // 1.0 = plate fills viewport; >1 zooms in on center; <1 shrinks plate

void main() {
  // Apply zoom around plate center. We DON'T clip outside [0,1]² — the
  // Chladni cos math is naturally periodic, so the pattern tiles to fill
  // the viewport at any zoom level.
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
    // Antisymmetric Chladni — table only contains m < n pairs.
    float term = 0.5 * (cos(mPi * puv.x) * cos(nPi * puv.y)
                      - cos(nPi * puv.x) * cos(mPi * puv.y));
    field += term * w;
    colorAccum += u_colors[i] * w;
    weightAccum += w;
  }
  float mag = abs(field);
  float node = max(0.0, 1.0 - mag * 9.0);

  // Center-driver bolt: ever-present small sand pile + thin nodal ring.
  float rCenter = length(puv - vec2(0.5, 0.5));
  float centerBlob = smoothstep(0.025, 0.015, rCenter);
  float centerRing = smoothstep(0.012, 0.0, abs(rCenter - 0.075));
  node = max(node, max(centerBlob * 0.55, centerRing * 0.75));

  if (node <= 0.04) discard;
  vec3 baseColor = weightAccum > 0.0 ? colorAccum / weightAccum : vec3(0.85);
  vec3 finalColor = mix(vec3(0.95), baseColor, 0.30);
  gl_FragColor = vec4(finalColor, node * 0.85);
}
`;

// Latest snapshot of the main app's state. Updated by BroadcastChannel
// messages; rendered every animation frame.
let latestOscillators = null;
let lastMessageTime = 0;

function initWebGL() {
  gl = canvas.getContext("webgl", {
    premultipliedAlpha: false,
    antialias: true,
    alpha: false,
    // Keep last-drawn frame readable for toBlob snapshots; tiny perf hit only.
    preserveDrawingBuffer: true
  });
  if (!gl) {
    disconnected.textContent = "WebGL not available in this browser.";
    disconnected.classList.add("shown");
    return;
  }
  const vs = compileShader(gl.VERTEX_SHADER, VS);
  const fs = compileShader(gl.FRAGMENT_SHADER, FS);
  glProgram = gl.createProgram();
  gl.attachShader(glProgram, vs);
  gl.attachShader(glProgram, fs);
  gl.linkProgram(glProgram);
  if (!gl.getProgramParameter(glProgram, gl.LINK_STATUS)) {
    console.error(gl.getProgramInfoLog(glProgram));
    return;
  }
  glAttribs.position   = gl.getAttribLocation(glProgram, "a_position");
  glUniforms.modeCount = gl.getUniformLocation(glProgram, "u_modeCount");
  glUniforms.modes     = gl.getUniformLocation(glProgram, "u_modes");
  glUniforms.colors    = gl.getUniformLocation(glProgram, "u_colors");
  glUniforms.zoom      = gl.getUniformLocation(glProgram, "u_zoom");
  const buf = gl.createBuffer();
  gl.bindBuffer(gl.ARRAY_BUFFER, buf);
  gl.bufferData(gl.ARRAY_BUFFER,
    new Float32Array([-1, -1, 1, -1, -1, 1, 1, 1]), gl.STATIC_DRAW);
  gl.enable(gl.BLEND);
  gl.blendFunc(gl.SRC_ALPHA, gl.ONE_MINUS_SRC_ALPHA);
}

function compileShader(type, src) {
  const s = gl.createShader(type);
  gl.shaderSource(s, src);
  gl.compileShader(s);
  if (!gl.getShaderParameter(s, gl.COMPILE_STATUS)) {
    throw new Error("Shader compile failed: " + gl.getShaderInfoLog(s));
  }
  return s;
}

function resize() {
  const dpr = Math.min(window.devicePixelRatio || 1, 2);
  canvas.width = Math.round(window.innerWidth * dpr);
  canvas.height = Math.round(window.innerHeight * dpr);
  canvas.style.width = window.innerWidth + "px";
  canvas.style.height = window.innerHeight + "px";
  if (gl) gl.viewport(0, 0, canvas.width, canvas.height);
  if (sandCanvas) {
    sandCanvas.width = canvas.width;
    sandCanvas.height = canvas.height;
    sandCanvas.style.width = canvas.style.width;
    sandCanvas.style.height = canvas.style.height;
  }
}

function isVoiceSilenced(i, oscs) {
  const anySoloed = oscs.some((o) => o.isSoloed);
  return (anySoloed && !oscs[i].isSoloed) || oscs[i].isMuted;
}

function hslToRgb(h, s, l) {
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

// Reusable buffers — up to 4 voices × 2 crossfading modes per voice = 8.
const _modesBuf  = new Float32Array(24);
const _colorsBuf = new Float32Array(24);
// Mode objects parsed back out for the sand-sim's CPU field evaluation.
const _activeModes = [];

function render() {
  requestAnimationFrame(render);
  if (!gl) return;

  // Resolve current modes (shared between WebGL shader and sand particle sim).
  let modeCount = 0;
  _activeModes.length = 0;
  if (latestOscillators && latestOscillators.length > 0) {
    const audible = latestOscillators.filter((_, i) => !isVoiceSilenced(i, latestOscillators));
    const voiceCount = Math.min(4, audible.length);
    for (let i = 0; i < voiceCount; i++) {
      const osc = audible[i];
      const [a, b] = modePairForFreq(osc.frequencyHz);
      const [r, g, bcol] = hslToRgb(frequencyHue(osc.frequencyHz), 0.30, 0.85);
      for (const mode of [a, b]) {
        if (mode.weight < 0.001 || modeCount >= 8) continue;
        const w = mode.weight * osc.amplitude;
        _modesBuf[modeCount * 3 + 0] = mode.m;
        _modesBuf[modeCount * 3 + 1] = mode.n;
        _modesBuf[modeCount * 3 + 2] = w;
        _colorsBuf[modeCount * 3 + 0] = r;
        _colorsBuf[modeCount * 3 + 1] = g;
        _colorsBuf[modeCount * 3 + 2] = bcol;
        _activeModes.push({ m: mode.m, n: mode.n, weight: w });
        modeCount++;
      }
    }
  }

  // ── 1. WebGL Chladni field ──
  gl.clearColor(0, 0, 0, 1);
  gl.clear(gl.COLOR_BUFFER_BIT);
  if (modeCount > 0) {
    gl.useProgram(glProgram);
    gl.uniform1i(glUniforms.modeCount, modeCount);
    gl.uniform3fv(glUniforms.modes, _modesBuf);
    gl.uniform3fv(glUniforms.colors, _colorsBuf);
    gl.uniform1f(glUniforms.zoom, zoomLevel);
    gl.enableVertexAttribArray(glAttribs.position);
    gl.vertexAttribPointer(glAttribs.position, 2, gl.FLOAT, false, 0, 0);
    gl.drawArrays(gl.TRIANGLE_STRIP, 0, 4);
  }

  // ── 2. Sand particles ──
  if (sandEnabled) updateAndDrawSand(_activeModes);
}

// ──────────────────────────────────────────────────
// Sand particle simulation
// 3000 grains attracted to wherever |field| ≈ 0 (the nodal lines), with
// damping + tiny Brownian jitter. When frequency changes, particles
// physically migrate from old nodal positions to new ones because the
// gradient pulls them out of the now-antinodal regions they used to sit in.
// ──────────────────────────────────────────────────
let sandCanvas, sandCtx;
let sandEnabled = true;
const PARTICLE_COUNT = 3000;
const particles = new Float32Array(PARTICLE_COUNT * 4);  // x, y, vx, vy per particle

function initSand() {
  sandCanvas = document.getElementById("sand");
  sandCtx = sandCanvas.getContext("2d");
  for (let i = 0; i < PARTICLE_COUNT; i++) {
    particles[i * 4 + 0] = Math.random();          // x
    particles[i * 4 + 1] = Math.random();          // y
    particles[i * 4 + 2] = 0;                      // vx
    particles[i * 4 + 3] = 0;                      // vy
  }
}

function updateAndDrawSand(modes) {
  if (!sandCtx) return;
  const w = sandCanvas.width;
  const h = sandCanvas.height;

  // Soft trail fade — grains leave a faint shimmer as they move.
  sandCtx.globalCompositeOperation = "destination-out";
  sandCtx.fillStyle = "rgba(0,0,0,0.12)";
  sandCtx.fillRect(0, 0, w, h);
  sandCtx.globalCompositeOperation = "source-over";

  if (modes.length === 0) return;

  // Tunable physics constants.
  const eps = 0.004;             // finite-diff step for gradient
  const attraction = 0.0010;     // strength of pull toward nodes
  const damping = 0.87;          // velocity decay each frame
  const jitter = 0.0006;         // Brownian motion

  for (let i = 0; i < PARTICLE_COUNT; i++) {
    const ix = i * 4;
    let x = particles[ix + 0];
    let y = particles[ix + 1];
    let vx = particles[ix + 2];
    let vy = particles[ix + 3];

    // Gradient of |field|: sign(field) * gradient(field). Move opposite the
    // gradient → toward lower |field| → toward nodal lines.
    const f = chladniField(x, y, modes);
    const fdx = (chladniField(x + eps, y, modes) - f) / eps;
    const fdy = (chladniField(x, y + eps, modes) - f) / eps;
    const s = f > 0 ? 1 : -1;
    vx -= fdx * s * attraction;
    vy -= fdy * s * attraction;
    vx *= damping;
    vy *= damping;
    vx += (Math.random() - 0.5) * jitter;
    vy += (Math.random() - 0.5) * jitter;
    x += vx;
    y += vy;
    // Wrap at edges so grains can drift across the plate.
    if (x < 0) x += 1; else if (x > 1) x -= 1;
    if (y < 0) y += 1; else if (y > 1) y -= 1;

    particles[ix + 0] = x;
    particles[ix + 1] = y;
    particles[ix + 2] = vx;
    particles[ix + 3] = vy;
  }

  // Draw all grains in one fillStyle change — warm pale sand. Particles
  // live in plate coords [0,1]; project to screen via the zoom transform
  // so they ride the same scaling as the WebGL field underneath.
  sandCtx.fillStyle = "rgba(255, 240, 215, 0.9)";
  const z = zoomLevel;
  const sizePx = Math.max(0.7, 1.4 * Math.sqrt(z));  // bigger grains when zoomed in
  for (let i = 0; i < PARTICLE_COUNT; i++) {
    const ix = i * 4;
    const sx = (particles[ix + 0] - 0.5) * z + 0.5;
    const sy = (particles[ix + 1] - 0.5) * z + 0.5;
    if (sx < 0 || sx > 1 || sy < 0 || sy > 1) continue;  // off the plate
    sandCtx.fillRect(sx * w - sizePx * 0.5, sy * h - sizePx * 0.5, sizePx, sizePx);
  }
}

// ──────────────────────────────────────────────────
// State sync via BroadcastChannel
// ──────────────────────────────────────────────────
const channel = new BroadcastChannel("drone-meditations-chladni");

channel.addEventListener("message", (e) => {
  const msg = e.data;
  if (!msg || msg.type !== "state") return;
  latestOscillators = msg.oscillators;
  lastMessageTime = Date.now();
  if (disconnected.classList.contains("shown")) {
    disconnected.classList.remove("shown");
  }
  syncControls(msg.oscillators);
});

// ──────────────────────────────────────────────────
// Bottom controls strip
// ──────────────────────────────────────────────────
const FREQ_MIN = 20;
const FREQ_MAX = 2000;
const LOG_LO = Math.log2(FREQ_MIN);
const LOG_HI = Math.log2(FREQ_MAX);

function syncControls(oscs) {
  if (!oscs) return;
  const anySoloed = oscs.some((o) => o.isSoloed);
  document.querySelectorAll(".ctrl-strip").forEach((strip, i) => {
    const o = oscs[i]; if (!o) return;
    const slider = strip.querySelector('[data-role="freq"]');
    const readout = strip.querySelector('[data-role="freq-readout"]');
    const solo = strip.querySelector('[data-role="solo"]');
    const mute = strip.querySelector('[data-role="mute"]');
    const t = (Math.log2(Math.max(FREQ_MIN, o.frequencyHz)) - LOG_LO) / (LOG_HI - LOG_LO);
    if (document.activeElement !== slider) slider.value = t.toFixed(4);
    slider.style.setProperty("--fill", `${Math.round(t * 100)}%`);
    readout.textContent = o.frequencyHz.toFixed(2) + " Hz";
    solo.classList.toggle("on", !!o.isSoloed);
    mute.classList.toggle("on", !!o.isMuted);
    const silenced = (anySoloed && !o.isSoloed) || o.isMuted;
    strip.classList.toggle("silenced", silenced);
  });
}

// Post commands back to the main window so it updates audio + state.
document.querySelectorAll(".ctrl-strip").forEach((strip) => {
  const i = parseInt(strip.dataset.osc, 10);
  strip.querySelector('[data-role="freq"]').addEventListener("input", (e) => {
    const t = parseFloat(e.target.value);
    const hz = Math.pow(2, LOG_LO + t * (LOG_HI - LOG_LO));
    channel.postMessage({ type: "command", cmd: "setFrequency", oscIndex: i, value: hz });
  });
  strip.querySelector('[data-role="solo"]').addEventListener("click", () => {
    channel.postMessage({ type: "command", cmd: "toggleSolo", oscIndex: i });
  });
  strip.querySelector('[data-role="mute"]').addEventListener("click", () => {
    channel.postMessage({ type: "command", cmd: "toggleMute", oscIndex: i });
  });
});

// Show "disconnected" hint if the main window has been quiet for ~3s
setInterval(() => {
  if (!latestOscillators) return;
  if (Date.now() - lastMessageTime > 3000) {
    disconnected.classList.add("shown");
  }
}, 1000);

// Initial poke — the main window may not have broadcasted recently because
// nothing's changing. Ask it to send the current state.
channel.postMessage({ type: "request-state" });

// ESC closes the window, S snapshots the pattern, G toggles sand layer
window.addEventListener("keydown", (e) => {
  if (e.key === "Escape") window.close();
  else if (e.key === "s" || e.key === "S") snapshot();
  else if (e.key === "g" || e.key === "G") setSandEnabled(!sandEnabled);
});

document.getElementById("snapshot-btn").addEventListener("click", snapshot);

function snapshot() {
  // Snapshot the composite (WebGL field + sand layer screen-blended) into a
  // temporary canvas, then PNG-export from that.
  if (gl) render();
  const w = canvas.width, h = canvas.height;
  const composite = document.createElement("canvas");
  composite.width = w;
  composite.height = h;
  const ctx = composite.getContext("2d");
  ctx.fillStyle = "#000";
  ctx.fillRect(0, 0, w, h);
  ctx.drawImage(canvas, 0, 0);
  if (sandEnabled && sandCanvas) {
    ctx.globalCompositeOperation = "screen";
    ctx.drawImage(sandCanvas, 0, 0);
    ctx.globalCompositeOperation = "source-over";
  }
  composite.toBlob((blob) => {
    if (!blob) return;
    const url = URL.createObjectURL(blob);
    const a = document.createElement("a");
    a.href = url;
    const now = new Date();
    const stamp = `${now.getFullYear()}-${String(now.getMonth() + 1).padStart(2,"0")}-${String(now.getDate()).padStart(2,"0")}_${String(now.getHours()).padStart(2,"0")}${String(now.getMinutes()).padStart(2,"0")}${String(now.getSeconds()).padStart(2,"0")}`;
    a.download = `chladni-${stamp}.png`;
    document.body.appendChild(a);
    a.click();
    document.body.removeChild(a);
    setTimeout(() => URL.revokeObjectURL(url), 500);
  }, "image/png");
}

initWebGL();
initSand();
resize();
window.addEventListener("resize", resize);

// Sand-layer toggle button + G shortcut.
const sandToggleBtn = document.getElementById("sand-toggle");
function setSandEnabled(on) {
  sandEnabled = on;
  sandToggleBtn.classList.toggle("active", on);
  if (!on && sandCtx) sandCtx.clearRect(0, 0, sandCanvas.width, sandCanvas.height);
}
sandToggleBtn.addEventListener("click", () => setSandEnabled(!sandEnabled));
setSandEnabled(true);

// ──────────────────────────────────────────────────
// Zoom: vertical slider + scroll-wheel + persist
// ──────────────────────────────────────────────────
let zoomLevel = 1.0;
const ZOOM_MIN = 0.25, ZOOM_MAX = 4.0;
const zoomSlider = document.getElementById("zoom-slider");
const zoomReadout = document.getElementById("zoom-readout");

function setZoom(z) {
  zoomLevel = Math.max(ZOOM_MIN, Math.min(ZOOM_MAX, z));
  zoomSlider.value = zoomLevel.toFixed(3);
  zoomReadout.textContent = zoomLevel.toFixed(2) + "×";
  try { localStorage.setItem("chladni-popup-zoom", String(zoomLevel)); } catch {}
}

// Restore prior zoom; default 1.0.
try {
  const saved = parseFloat(localStorage.getItem("chladni-popup-zoom"));
  if (Number.isFinite(saved)) setZoom(saved); else setZoom(1.0);
} catch { setZoom(1.0); }

zoomSlider.addEventListener("input", (e) => setZoom(parseFloat(e.target.value)));

// Scroll-wheel zoom — multiplicative so it feels even at any current zoom.
window.addEventListener("wheel", (e) => {
  // Ignore if hovering over the controls strip so wheel doesn't fight scrolling.
  if (e.target.closest && e.target.closest("#popup-controls")) return;
  e.preventDefault();
  const factor = Math.exp(-e.deltaY * 0.0015);
  setZoom(zoomLevel * factor);
}, { passive: false });

render();
