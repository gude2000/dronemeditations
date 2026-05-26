// User-preset persistence.
//
// Preset metadata (per-osc settings) lives in localStorage as JSON — small,
// synchronous, fine for a few hundred presets.
// Sample audio blobs live in IndexedDB (`dronemeditations` DB, `samples`
// store) keyed by a generated id. The preset JSON references samples by
// id so multiple presets can share the same underlying file without dup.

const DB_NAME = "dronemeditations";
const DB_VERSION = 2;
const SAMPLE_STORE = "samples";
const SNAPSHOT_STORE = "snapshots";
const PRESETS_KEY = "dronemeditations:user-presets";
const SNAPSHOTS_META_KEY = "dronemeditations:snapshot-meta";

function openDB() {
  return new Promise((resolve, reject) => {
    const req = indexedDB.open(DB_NAME, DB_VERSION);
    req.onupgradeneeded = () => {
      const db = req.result;
      if (!db.objectStoreNames.contains(SAMPLE_STORE)) {
        db.createObjectStore(SAMPLE_STORE, { keyPath: "id" });
      }
      if (!db.objectStoreNames.contains(SNAPSHOT_STORE)) {
        db.createObjectStore(SNAPSHOT_STORE, { keyPath: "id" });
      }
    };
    req.onsuccess = () => resolve(req.result);
    req.onerror = () => reject(req.error);
  });
}

async function tx(mode, fn) {
  const db = await openDB();
  return new Promise((resolve, reject) => {
    const t = db.transaction(SAMPLE_STORE, mode);
    const store = t.objectStore(SAMPLE_STORE);
    const result = fn(store);
    t.oncomplete = () => resolve(result);
    t.onerror = () => reject(t.error);
  });
}

export async function putSample(id, blob, name, type) {
  return tx("readwrite", (s) => s.put({ id, blob, name, type }));
}

export async function getSample(id) {
  const db = await openDB();
  return new Promise((resolve, reject) => {
    const t = db.transaction(SAMPLE_STORE, "readonly");
    const req = t.objectStore(SAMPLE_STORE).get(id);
    req.onsuccess = () => resolve(req.result || null);
    req.onerror = () => reject(req.error);
  });
}

export async function deleteSample(id) {
  return tx("readwrite", (s) => s.delete(id));
}

// ─── preset list (localStorage) ──────────────────────────────

export function loadUserPresets() {
  try {
    const raw = localStorage.getItem(PRESETS_KEY);
    return raw ? JSON.parse(raw) : [];
  } catch {
    return [];
  }
}

export function saveUserPresets(list) {
  localStorage.setItem(PRESETS_KEY, JSON.stringify(list));
}

export function newPresetId() {
  return `preset-${Date.now().toString(36)}-${Math.random().toString(36).slice(2, 8)}`;
}

export function newSampleId() {
  return `sample-${Date.now().toString(36)}-${Math.random().toString(36).slice(2, 8)}`;
}

// ─── browser sample library (localStorage meta + IndexedDB blobs) ─────────
//
// "Library" samples are user-uploaded files the user has explicitly chosen
// to keep — separate from preset-attached samples (which are owned by their
// preset). A library entry is a small metadata row pointing to a blob already
// in the IndexedDB sample store, so the Bundled ▾ picker can list them
// alongside the shipped samples on subsequent visits.
//
// Schema per entry: { id (sample id in IndexedDB), name, addedAt }.

const LIBRARY_META_KEY = "dronemeditations:library-samples";

export function loadLibrarySamples() {
  try {
    const raw = localStorage.getItem(LIBRARY_META_KEY);
    return raw ? JSON.parse(raw) : [];
  } catch { return []; }
}

export function saveLibrarySamples(list) {
  localStorage.setItem(LIBRARY_META_KEY, JSON.stringify(list));
}

// ─── per-voice presets (localStorage) ────────────────────────

const VOICE_PRESETS_KEY = "dronemeditations:voice-presets";

export function loadVoicePresets() {
  try {
    const raw = localStorage.getItem(VOICE_PRESETS_KEY);
    return raw ? JSON.parse(raw) : [];
  } catch { return []; }
}

export function saveVoicePresets(list) {
  localStorage.setItem(VOICE_PRESETS_KEY, JSON.stringify(list));
}

export function newVoicePresetId() {
  return `voice-${Date.now().toString(36)}-${Math.random().toString(36).slice(2, 8)}`;
}

// ─── user journeys (localStorage) ────────────────────────────
//
// Schema: { id, name, description, createdAt, stages: [{ durationSec,
// presetId, driftSceneId, hint }] }. Validation lives in main.js so the
// composer can show inline errors before persisting.

const USER_JOURNEYS_KEY = "dronemeditations:user-journeys";

export function loadUserJourneys() {
  try {
    const raw = localStorage.getItem(USER_JOURNEYS_KEY);
    return raw ? JSON.parse(raw) : [];
  } catch { return []; }
}

export function saveUserJourneys(list) {
  localStorage.setItem(USER_JOURNEYS_KEY, JSON.stringify(list));
}

export function newUserJourneyId() {
  return `userj-${Date.now().toString(36)}-${Math.random().toString(36).slice(2, 8)}`;
}

// ─── cymatics snapshots (IndexedDB blobs + localStorage metadata) ────────
//
// Blobs are large so they live in IndexedDB. Metadata (id, name, timestamp,
// chord, frequencies, drift scene, etc.) is a small JSON array in
// localStorage for fast list rendering.

export function loadSnapshotMeta() {
  try {
    const raw = localStorage.getItem(SNAPSHOTS_META_KEY);
    return raw ? JSON.parse(raw) : [];
  } catch { return []; }
}
export function saveSnapshotMeta(list) {
  localStorage.setItem(SNAPSHOTS_META_KEY, JSON.stringify(list));
}
export function newSnapshotId() {
  return `snap-${Date.now().toString(36)}-${Math.random().toString(36).slice(2, 8)}`;
}

export async function putSnapshotBlob(id, blob) {
  const db = await openDB();
  return new Promise((resolve, reject) => {
    const t = db.transaction(SNAPSHOT_STORE, "readwrite");
    t.objectStore(SNAPSHOT_STORE).put({ id, blob });
    t.oncomplete = () => resolve();
    t.onerror = () => reject(t.error);
  });
}
export async function getSnapshotBlob(id) {
  const db = await openDB();
  return new Promise((resolve, reject) => {
    const t = db.transaction(SNAPSHOT_STORE, "readonly");
    const req = t.objectStore(SNAPSHOT_STORE).get(id);
    req.onsuccess = () => resolve(req.result ? req.result.blob : null);
    req.onerror = () => reject(req.error);
  });
}
export async function deleteSnapshotBlob(id) {
  const db = await openDB();
  return new Promise((resolve, reject) => {
    const t = db.transaction(SNAPSHOT_STORE, "readwrite");
    t.objectStore(SNAPSHOT_STORE).delete(id);
    t.oncomplete = () => resolve();
    t.onerror = () => reject(t.error);
  });
}
