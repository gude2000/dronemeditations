// v1.1 cross-device user-preset sharing for the web app.
//
// Mirrors the iOS .dronepreset file format so a preset saved in the
// iPhone app loads in the browser app and vice versa. The envelope is
// the same JSON shape on both platforms:
//
//   {
//     "version": 1,
//     "preset":  { …UserPreset… },
//     "samples": [ { "filename": "…", "data": "<base64>", "name": "…",
//                    "mime": "audio/wav" }, … ]
//   }
//
// On iOS the sample is identified by `sampleStoredFilename` (the file
// inside Documents/DroneSamples/). On web the sample is identified by
// `sampleRef.id` (the IndexedDB key in the `samples` store). For
// cross-platform compat the envelope uses a single string per sample
// — interpreted as a filename on iOS, as an IndexedDB id on web.

import {
  loadUserPresets, saveUserPresets, newPresetId, newSampleId,
  putSample, getSample
} from "./storage.js?v=40";

const CURRENT_VERSION = 1;
const FILE_EXTENSION = "dronepreset";

// Lazy standalone AudioContext used to decode embedded sample blobs
// (WebM/Opus, MP4/AAC, MP3, OGG, etc.) into raw PCM at export time so
// we can re-encode as WAV. Kept separate from the main engine context
// so we don't perturb live playback state. Created on first use.
let _decoderCtx = null;
function ensureDecoderCtx() {
  if (!_decoderCtx) {
    const Ctor = window.AudioContext || window.webkitAudioContext;
    if (!Ctor) throw new Error("Web Audio API unavailable.");
    _decoderCtx = new Ctor();
  }
  return _decoderCtx;
}

// MARK: - Export
//
// Pack a saved preset + every IndexedDB sample blob it references into
// a single .dronepreset JSON file and trigger a browser download.
// Returns true on success, false if the preset id wasn't found.
export async function exportUserPresetDownload(presetId) {
  const presets = loadUserPresets();
  const p = presets.find((x) => x.id === presetId);
  if (!p) return false;

  // Collect referenced samples once each (multiple voices may share
  // the same sample id; we embed it once and let both voices point at
  // the same filename on the receiving side).
  //
  // v1 cross-platform: transcode every embedded sample to 16-bit PCM
  // WAV at export time. The IndexedDB store can hold WebM/Opus,
  // MP4/AAC, MP3, OGG, etc. depending on the browser + how the sample
  // arrived (recording vs. file upload). iOS's AVAudioFile accepts
  // WAV / AAC / MP3 / AIFF but not WebM/Opus, so shipping the raw
  // bytes makes the preset platform-dependent. Decode → WAV makes
  // the .dronepreset universal. We also append a real file extension
  // to the sample filename because AVAudioFile sniffs by extension.
  //
  // Renaming the filename means the IndexedDB id the original voice
  // points at no longer matches what we wrote in samples[i].filename,
  // so we also rewrite the exported voice's sampleRef.id (and add
  // sampleStoredFilename for iOS interop). Track old→new in a map.
  const samples = [];
  const idRename = new Map();   // oldRef.id → newFilename (= IndexedDB key on re-import)
  for (const v of p.oscillators || []) {
    const ref = v.sampleRef;
    if (!ref || !ref.id || idRename.has(ref.id)) continue;
    try {
      const rec = await getSample(ref.id);
      if (!rec || !rec.blob) continue;
      let wavBlob = null;
      try {
        wavBlob = await blobToWavBlob(rec.blob);
      } catch (e) {
        // Some browsers can't decode every format their MediaRecorder
        // emits (rare, but possible with Opus on older Safari).
        // Fall back to raw blob so the export still produces a file
        // — receiver gets the same portability problem we had before,
        // but at least the path doesn't break for cases where the
        // transcode would succeed.
        console.warn("Sample → WAV transcode failed; embedding raw blob.", e);
      }
      const outBlob = wavBlob || rec.blob;
      const outMime = wavBlob ? "audio/wav" : (rec.type || rec.blob.type || "audio/wav");
      const ext = wavBlob ? "wav" : extensionForMime(outMime);
      const filename = ref.id.endsWith(`.${ext}`) ? ref.id : `${ref.id}.${ext}`;
      const data = await blobToBase64(outBlob);
      samples.push({
        filename,
        name: ref.name || rec.name || "sample",
        mime: outMime,
        data
      });
      idRename.set(ref.id, filename);
    } catch { /* sample missing — skip */ }
  }

  // Build a shallow-cloned preset whose voices reference the renamed
  // filenames. Original presets on this device are untouched. The
  // sampleStoredFilename mirror lets iOS pick up the reference
  // without needing translateWebEnumStrings to fall back to sampleRef.
  const exportedPreset = {
    ...p,
    oscillators: (p.oscillators || []).map((v) => {
      if (!v) return v;
      const newName = v.sampleRef && idRename.get(v.sampleRef.id);
      if (!newName) return v;
      return {
        ...v,
        sampleRef: { ...v.sampleRef, id: newName },
        sampleStoredFilename: newName
      };
    })
  };

  const envelope = { version: CURRENT_VERSION, preset: exportedPreset, samples };
  const json = JSON.stringify(envelope, null, 2);
  const blob = new Blob([json], { type: "application/x-dronepreset" });
  const url = URL.createObjectURL(blob);

  // Trigger a download via an off-screen anchor — works in every
  // mainstream browser without permission prompts. The browser cleans
  // up the object URL after a microtask; revoke explicitly so memory
  // doesn't leak if the user spams Share.
  const a = document.createElement("a");
  a.href = url;
  a.download = `${sanitizeFilename(p.name)}.${FILE_EXTENSION}`;
  document.body.appendChild(a);
  a.click();
  document.body.removeChild(a);
  setTimeout(() => URL.revokeObjectURL(url), 1000);
  return true;
}

// MARK: - Import
//
// Decode a .dronepreset (or compatible JSON) File the user picked,
// materialize any embedded samples into IndexedDB, and append the
// preset to userPresets with a freshly-issued id so importing twice
// produces two distinct entries. Returns the preset's display name on
// success, throws an Error on a malformed file.
export async function importUserPresetFromFile(file) {
  if (!file) throw new Error("No file picked.");
  const text = await file.text();
  let env;
  try { env = JSON.parse(text); }
  catch { throw new Error("This file isn't a Drone Meditations preset."); }

  if (typeof env !== "object" || env === null || !env.preset) {
    throw new Error("Preset file is missing the preset payload.");
  }
  if (typeof env.version === "number" && env.version > CURRENT_VERSION) {
    throw new Error(
      `This preset uses a newer format (v${env.version}) than this version of Drone Meditations understands. Please refresh.`
    );
  }

  // Materialize each embedded sample. Use the envelope's filename as
  // the IndexedDB id so the preset's sampleRef.id (which equals the
  // filename) still resolves on this device. If the same id already
  // exists locally, leave it — could be a previous import or another
  // preset on this device.
  for (const s of env.samples || []) {
    if (!s || !s.filename || !s.data) continue;
    const existing = await getSample(s.filename).catch(() => null);
    if (existing) continue;
    const bytes = base64ToBytes(s.data);
    const blob = new Blob([bytes], { type: s.mime || "audio/wav" });
    await putSample(s.filename, blob, s.name || "sample", s.mime || "audio/wav");
  }

  // Re-id the preset so duplicates never overwrite. Preserve
  // createdAt so the receiver sees the author's save time.
  // v1 iOS interop: iOS UserPreset.Voice references samples by
  // `sampleStoredFilename` (the file inside Documents/DroneSamples/).
  // Web preset voices reference samples by `sampleRef: { id, name }`
  // where id is the IndexedDB key. Translate: when an imported voice
  // has sampleStoredFilename, look it up in the (just-written)
  // samples store and synthesize a sampleRef pointing at the same
  // IndexedDB row. Otherwise the imported preset would have the
  // sample bytes sitting in IndexedDB but no link from the voice.
  const orig = env.preset;
  const sampleByFilename = new Map();
  for (const s of env.samples || []) {
    if (s && s.filename) sampleByFilename.set(s.filename, s);
  }
  const translatedOscs = (orig.oscillators || []).map((v) => {
    let out = v;
    if (v && !v.sampleRef && v.sampleStoredFilename) {
      const meta = sampleByFilename.get(v.sampleStoredFilename);
      const name = (meta && meta.name) || v.sampleName || v.sampleStoredFilename;
      out = { ...out, sampleRef: { id: v.sampleStoredFilename, name } };
    }
    // v1: accept either web's sampleBaseFreqHz or iOS's sampleNativeBaseFreq,
    // mirror so subsequent load code sees both.
    if (out && out.sampleNativeBaseFreq != null && out.sampleBaseFreqHz == null) {
      out = { ...out, sampleBaseFreqHz: out.sampleNativeBaseFreq };
    }
    return out;
  });
  const p = {
    id: newPresetId(),
    name: orig.name || "Imported Preset",
    createdAt: orig.createdAt || new Date().toISOString(),
    keyId: orig.keyId,
    octave: orig.octave,
    chordId: orig.chordId,
    tuningId: orig.tuningId,
    masterVolume: orig.masterVolume,
    oscillators: translatedOscs
  };

  const list = loadUserPresets();
  saveUserPresets([p, ...list]);
  return p.name;
}

// MARK: - Helpers

function sanitizeFilename(name) {
  let s = (name || "").trim();
  if (!s) s = "Drone Preset";
  s = s.replace(/[/:\\?*"<>|]/g, "-");
  if (s.length > 80) s = s.slice(0, 80);
  return s;
}

/**
 * Read a Blob as base64 (without the data: URI prefix).
 * Uses FileReader so we don't pull the bytes into a giant intermediate
 * string in JS land — for a multi-MB sample this matters.
 */
function blobToBase64(blob) {
  return new Promise((resolve, reject) => {
    const reader = new FileReader();
    reader.onload = () => {
      const result = reader.result; // "data:<mime>;base64,<payload>"
      const idx = String(result).indexOf(",");
      resolve(idx >= 0 ? String(result).slice(idx + 1) : "");
    };
    reader.onerror = () => reject(reader.error);
    reader.readAsDataURL(blob);
  });
}

/** Decode base64 → Uint8Array. atob() works on every modern browser. */
function base64ToBytes(b64) {
  const binary = atob(String(b64));
  const out = new Uint8Array(binary.length);
  for (let i = 0; i < binary.length; i++) out[i] = binary.charCodeAt(i);
  return out;
}

/**
 * Map a recognized audio MIME type to a sensible file extension. Used
 * as the FALLBACK path when transcoding to WAV fails — the original
 * blob still gets a filename that AVAudioFile / generic decoders can
 * sniff. Unknown MIMEs default to `wav` so the file at least gets a
 * recognizable extension and AVAudioFile will reject it cleanly
 * rather than silently failing.
 */
function extensionForMime(mime) {
  const m = String(mime || "").toLowerCase();
  if (m.includes("wav"))   return "wav";
  if (m.includes("mp3") || m.includes("mpeg")) return "mp3";
  if (m.includes("m4a") || m.includes("aac")  || m.includes("mp4")) return "m4a";
  if (m.includes("ogg") || m.includes("opus") || m.includes("webm")) return "ogg";
  if (m.includes("flac"))  return "flac";
  return "wav";
}

/**
 * Decode any browser-supported audio blob (WebM/Opus, MP4/AAC, MP3,
 * OGG, WAV, etc.) → 16-bit PCM WAV Blob. Used at preset-export time
 * so the resulting `.dronepreset` is universally playable on iOS,
 * which can't decode WebM/Opus.
 *
 * The standalone decoder context is created lazily and reused — we
 * don't want to perturb the main engine's playback state, but we
 * also don't want to spin up an AudioContext per sample for a multi-
 * voice preset.
 */
async function blobToWavBlob(blob) {
  const ctx = ensureDecoderCtx();
  const arrayBuffer = await blob.arrayBuffer();
  // decodeAudioData mutates the buffer on some old WebKits — slice
  // first so the caller's original bytes stay intact in case we ever
  // need to fall back.
  const audioBuffer = await ctx.decodeAudioData(arrayBuffer.slice(0));
  return audioBufferToWavBlob(audioBuffer);
}

/**
 * Encode an AudioBuffer to a 16-bit PCM WAV Blob (RIFF/WAVE, format 1
 * PCM). Multi-channel is interleaved per the WAV spec. Compact enough
 * that we can keep it inline rather than pulling in a library — the
 * format hasn't changed since 1991.
 *
 * Returns a Blob with `audio/wav` type, ready for FileReader → base64
 * embedding in the .dronepreset envelope.
 */
function audioBufferToWavBlob(audioBuffer) {
  const numChannels = audioBuffer.numberOfChannels;
  const sampleRate  = audioBuffer.sampleRate;
  const numFrames   = audioBuffer.length;
  const bytesPerSample = 2;
  const blockAlign  = numChannels * bytesPerSample;
  const byteRate    = sampleRate * blockAlign;
  const dataSize    = numFrames * blockAlign;
  const headerSize  = 44;
  const buffer = new ArrayBuffer(headerSize + dataSize);
  const view   = new DataView(buffer);

  // RIFF / WAVE header.
  writeString(view, 0, "RIFF");
  view.setUint32(4, 36 + dataSize, true);
  writeString(view, 8, "WAVE");
  // fmt subchunk.
  writeString(view, 12, "fmt ");
  view.setUint32(16, 16, true);            // subchunk1Size (PCM)
  view.setUint16(20, 1, true);             // audioFormat (1 = PCM)
  view.setUint16(22, numChannels, true);
  view.setUint32(24, sampleRate, true);
  view.setUint32(28, byteRate, true);
  view.setUint16(32, blockAlign, true);
  view.setUint16(34, bytesPerSample * 8, true); // bitsPerSample
  // data subchunk.
  writeString(view, 36, "data");
  view.setUint32(40, dataSize, true);

  // Interleaved PCM samples. Read each channel into its own Float32Array
  // once, then walk frames writing channel-by-channel.
  const channelData = [];
  for (let c = 0; c < numChannels; c++) channelData.push(audioBuffer.getChannelData(c));
  let offset = headerSize;
  for (let i = 0; i < numFrames; i++) {
    for (let c = 0; c < numChannels; c++) {
      // Clamp to [-1, 1] then scale to int16. Float32 from
      // decodeAudioData is typically already in range, but a normalized
      // recording can clip at the boundary — clamp keeps us safe.
      let s = channelData[c][i];
      if (s > 1)  s = 1;
      if (s < -1) s = -1;
      view.setInt16(offset, s < 0 ? s * 0x8000 : s * 0x7FFF, true);
      offset += 2;
    }
  }
  return new Blob([buffer], { type: "audio/wav" });
}

function writeString(view, offset, s) {
  for (let i = 0; i < s.length; i++) view.setUint8(offset + i, s.charCodeAt(i));
}
