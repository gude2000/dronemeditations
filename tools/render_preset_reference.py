#!/usr/bin/env python3
"""
Render web/preset-reference.html from the built-in preset definitions
in DroneMeditations/Models/Preset.swift and web/js/music.js.

Auto-summarises each preset's voices + FX so users have a single
manual page they can browse to understand what's in each patch
without loading + probing every one. Drone Artists category can be
enriched with hand-curated descriptions via
tools/drone_artists_descriptions.json (per-preset narrative prose
that supplements the auto-generated voice table).

Run from repo root:
    python3 tools/render_preset_reference.py

Re-run after editing Preset.swift, music.js, or the curated JSON.
"""

import json
import pathlib
import re
import html as html_mod
from math import log2

ROOT = pathlib.Path(__file__).resolve().parent.parent
IOS_PRESET_FILE = ROOT / "DroneMeditations" / "Models" / "Preset.swift"
WEB_MUSIC_FILE = ROOT / "web" / "js" / "music.js"
CURATED_JSON = ROOT / "tools" / "drone_artists_descriptions.json"
OUT_FILE = ROOT / "web" / "preset-reference.html"

NOTE_NAMES = ["C", "C♯", "D", "D♯", "E", "F", "F♯", "G", "G♯", "A", "A♯", "B"]


def hz_to_note(hz):
    """Return 'A3 (220.00 Hz)' or with cents offset if non-12-TET."""
    if hz is None or hz <= 0:
        return "—"
    semis = 12 * log2(hz / 440.0) + 69
    midi = round(semis)
    cents = round((semis - midi) * 100)
    name = NOTE_NAMES[midi % 12]
    octave = (midi // 12) - 1
    base = f"{name}{octave}"
    if abs(cents) >= 3:
        return f"{base}{cents:+d}¢ ({hz:.2f} Hz)"
    return f"{base} ({hz:.2f} Hz)"


def pan_label(pan):
    p = float(pan or 0)
    if p < -0.7: return "hard L"
    if p < -0.3: return "L"
    if p < -0.05: return "slight L"
    if p <= 0.05: return "centred"
    if p <= 0.3: return "slight R"
    if p <= 0.7: return "R"
    return "hard R"


# ─────────── iOS parser ───────────


def parse_ios_presets():
    """Match each Preset(...) call by paren-balancing and pull voices
    out by name regardless of whether they come from a literal
    `[Voice(...), ...]` array or a closure-with-return like
    `{ let dly = ...; return [...] }()` (used by several Drone Artists
    presets that reuse computed FX configurations across voices)."""
    text = IOS_PRESET_FILE.read_text()
    out = []
    i = 0
    while True:
        m = re.search(r'\bPreset\("([^"]+)",\s*\.(\w+)', text[i:])
        if not m:
            break
        name = m.group(1)
        category = m.group(2)
        body_start = i + m.start()
        # Find the opening ( of this Preset call — it's the ( right
        # after "Preset" in our match. We've already consumed the
        # category enum; find the next ( from m.start.
        open_paren = text.find("(", i + m.start())
        # Now paren-match.
        depth = 1
        j = open_paren + 1
        in_str = False
        while j < len(text) and depth > 0:
            ch = text[j]
            if in_str:
                if ch == '"' and text[j - 1] != "\\":
                    in_str = False
            else:
                if ch == '"':
                    in_str = True
                elif ch == "(":
                    depth += 1
                elif ch == ")":
                    depth -= 1
            j += 1
        body = text[open_paren + 1:j - 1]
        # Pull subtitle if present.
        sub_m = re.search(r'subtitle:\s*"([^"]*)"', body)
        subtitle = sub_m.group(1) if sub_m else ""
        voices = parse_ios_voices(body)
        out.append({
            "name": name,
            "category": category,
            "subtitle": subtitle,
            "voices": voices,
            "platforms": {"ios"},
        })
        i = j
    return out


def parse_ios_voices(text):
    """Parse Voice(...) blocks AND the L(hz)/R(hz)/C(hz)/silent shorthand
    used by the binaural / natural-resonance / cymatics / solfeggio
    categories. The helpers expand to single-voice patches with hard pan
    (L=-1, R=+1, C=0, silent=sentinel)."""
    voices = []
    i = 0
    while i < len(text):
        candidates = []
        for pat, kind in [
            (r'\bVoice\(', 'voice'),
            (r'\bL\(\s*([\-\d\.]+)\s*\)', 'L'),
            (r'\bR\(\s*([\-\d\.]+)\s*\)', 'R'),
            (r'\bC\(\s*([\-\d\.]+)\s*\)', 'C'),
            (r'\bsilent\b', 'silent'),
        ]:
            m = re.search(pat, text[i:])
            if m:
                candidates.append((m.start(), m, kind, pat))
        if not candidates:
            break
        # Take the earliest match
        candidates.sort(key=lambda c: c[0])
        rel_start, m, kind, _ = candidates[0]
        if kind == 'voice':
            start = i + m.end()
            depth = 1
            j = start
            while j < len(text) and depth > 0:
                if text[j] == '(': depth += 1
                elif text[j] == ')': depth -= 1
                j += 1
            voices.append(parse_voice_body(text[start:j - 1], swift=True))
            i = j
        elif kind in ('L', 'R', 'C'):
            hz = float(m.group(1))
            pan = {'L': -1.0, 'R': 1.0, 'C': 0.0}[kind]
            voices.append({"wave": "sine", "hz": hz, "pan": pan})
            i = i + m.end()
        elif kind == 'silent':
            voices.append({"silent": True})
            i = i + m.end()
    return voices


# ─────────── web parser ───────────


def parse_web_presets():
    text = WEB_MUSIC_FILE.read_text()
    # PRESETS = [ ... ] — pin to that array.
    m = re.search(r'export const PRESETS\s*=\s*\[', text)
    if not m:
        return []
    arr_start = m.end()
    depth = 1
    j = arr_start
    while j < len(text) and depth > 0:
        if text[j] == '[': depth += 1
        elif text[j] == ']': depth -= 1
        j += 1
    body = text[arr_start:j - 1]
    out = []
    i = 0
    while True:
        m = re.search(
            r'\{\s*id:\s*"([^"]+)",\s*name:\s*"([^"]+)",\s*category:\s*"([^"]+)"',
            body[i:],
        )
        if not m:
            break
        pid = m.group(1)
        name = m.group(2)
        category = m.group(3)
        after = i + m.end()
        sub_m = re.match(r',\s*sub:\s*"([^"]*)"', body[after:])
        if sub_m:
            sub = sub_m.group(1)
            after2 = after + sub_m.end()
        else:
            sub = ""
            after2 = after
        vm = re.search(r'voices:\s*\[', body[after2:])
        if not vm:
            i = after
            continue
        vstart = after2 + vm.end()
        depth = 1
        k = vstart
        while k < len(body) and depth > 0:
            if body[k] == '[': depth += 1
            elif body[k] == ']': depth -= 1
            k += 1
        voices = parse_web_voices(body[vstart:k - 1])
        out.append({
            "name": name,
            "id": pid,
            "category": category,
            "subtitle": sub,
            "voices": voices,
            "platforms": {"web"},
        })
        i = k
    return out


def parse_web_voices(text):
    """Each voice is V({...}) or SILENT."""
    voices = []
    i = 0
    while i < len(text):
        # First check for V({
        vm = re.search(r'V\(\{', text[i:])
        sm = re.search(r'\bSILENT\b', text[i:])
        # Pick whichever comes first
        if vm and (not sm or vm.start() < sm.start()):
            start = i + vm.end()
            depth = 1
            j = start
            while j < len(text) and depth > 0:
                if text[j] == '{': depth += 1
                elif text[j] == '}': depth -= 1
                j += 1
            voices.append(parse_voice_body(text[start:j - 1], swift=False))
            i = j
        elif sm:
            voices.append({"silent": True})
            i = i + sm.end()
        else:
            break
    return voices


# ─────────── voice body parser (both platforms) ───────────


def parse_voice_body(body, swift):
    v = {}

    def num(key):
        m = re.search(rf'\b{key}:\s*([\-\d\.]+)', body)
        return float(m.group(1)) if m else None

    def integer(key):
        n = num(key)
        return int(n) if n is not None else None

    def str_field(key):
        m = re.search(rf'\b{key}:\s*"([^"]*)"', body)
        return m.group(1) if m else None

    if swift:
        wm = re.search(r'wave:\s*\.(\w+)', body)
    else:
        wm = re.search(r'wave:\s*"(\w+)"', body)
    v["wave"] = wm.group(1) if wm else "sine"

    v["hz"] = num("hz")
    v["pan"] = num("pan")
    v["amp"] = num("amp")
    v["drive"] = num("drive")
    v["startDelaySec"] = num("startDelaySec")
    v["playDurationSec"] = num("playDurationSec")
    v["replayCount"] = integer("replayCount")
    v["bundledSampleName"] = str_field("bundledSampleName")
    v["sampleGranular"] = "sampleGranular: true" in body or "sampleGranular:true" in body

    # Filter
    if swift:
        fm = re.search(
            r"filter:\s*FilterState\(type:\s*\.(\w+),\s*cutoffHz:\s*([\d\.\-]+),\s*q:\s*([\d\.\-]+)\)",
            body,
        )
    else:
        fm = re.search(
            r'filter:\s*\{\s*type:\s*"(\w+)",\s*cutoffHz:\s*([\d\.\-]+),\s*q:\s*([\d\.\-]+)\s*\}',
            body,
        )
    if fm:
        v["filter"] = {
            "type": fm.group(1),
            "cutoffHz": float(fm.group(2)),
            "q": float(fm.group(3)),
        }

    # Reverb
    if swift:
        rm = re.search(r"reverb:\s*ReverbState\(decaySec:\s*([\d\.\-]+),\s*mix:\s*([\d\.\-]+)\)", body)
    else:
        rm = re.search(r'reverb:\s*\{\s*decaySec:\s*([\d\.\-]+),\s*mix:\s*([\d\.\-]+)\s*\}', body)
    if rm:
        v["reverb"] = {"decaySec": float(rm.group(1)), "mix": float(rm.group(2))}

    # Delay
    if swift:
        dm = re.search(
            r"delay:\s*DelayState\(timeSec:\s*([\d\.\-]+),\s*feedback:\s*([\d\.\-]+),\s*mix:\s*([\d\.\-]+)\)",
            body,
        )
    else:
        dm = re.search(
            r'delay:\s*\{\s*timeSec:\s*([\d\.\-]+),\s*feedback:\s*([\d\.\-]+),\s*mix:\s*([\d\.\-]+)\s*\}',
            body,
        )
    if dm:
        v["delay"] = {"timeSec": float(dm.group(1)), "feedback": float(dm.group(2)), "mix": float(dm.group(3))}

    # Grain
    if swift:
        gm = re.search(
            r"grain:\s*GrainState\(sizeMs:\s*([\d\.\-]+),\s*densityHz:\s*([\d\.\-]+),\s*jitter:\s*([\d\.\-]+),\s*panSpread:\s*([\d\.\-]+)\)",
            body,
        )
    else:
        gm = re.search(
            r'grain:\s*\{\s*sizeMs:\s*([\d\.\-]+),\s*densityHz:\s*([\d\.\-]+),\s*jitter:\s*([\d\.\-]+),\s*panSpread:\s*([\d\.\-]+)\s*\}',
            body,
        )
    if gm:
        v["grain"] = {
            "sizeMs": float(gm.group(1)),
            "densityHz": float(gm.group(2)),
            "jitter": float(gm.group(3)),
            "panSpread": float(gm.group(4)),
        }

    return v


# ─────────── merge & render ───────────


CATEGORY_DISPLAY = {
    "setup": "Setup",
    "droneArtists": "Drone Artists",
    "developerPatches": "Developer Patches",
    "naturalResonance": "Natural Resonance",
    "cymatics": "Cymatics",
    "solfeggio": "Solfeggio",
    "mysticComposers": "Mystic & Composers",
}

CAT_ORDER = [
    "Setup",
    "Drone Artists",
    "Developer Patches",
    "Modal",
    "Extensions",
    "Quartal & Open",
    "Microtonal",
    "Symmetric",
    "Natural Resonance",
    "Cymatics",
    "Solfeggio",
    "Mystic & Composers",
]


def merge_presets(ios, web):
    by_name = {}
    for p in ios:
        p["category_display"] = CATEGORY_DISPLAY.get(p["category"], p["category"])
        by_name[p["name"]] = p
    for p in web:
        if p["name"] in by_name:
            by_name[p["name"]]["platforms"].add("web")
        else:
            p["category_display"] = p["category"]
            by_name[p["name"]] = p
    return list(by_name.values())


WAVE_FRIENDLY = {
    "sine": "sine",
    "triangle": "triangle",
    "sawtooth": "sawtooth",
    "saw": "sawtooth",
    "square": "square",
    "whiteNoise": "white noise",
    "white_noise": "white noise",
    "pinkNoise": "pink noise",
    "pink_noise": "pink noise",
    "noise": "pink noise",
    "granular": "granular noise",
    "sample": "sample",
}


def voice_row(v, idx):
    if v.get("silent"):
        return [f"OSC {idx + 1}", "—", "—", "silent"]

    wave_raw = v.get("wave") or "sine"
    wave = WAVE_FRIENDLY.get(wave_raw, wave_raw)

    source = wave
    if v.get("bundledSampleName"):
        source = f"sample: {v['bundledSampleName']}"
        if v.get("sampleGranular"):
            source += " (granular)"
    elif wave_raw == "sample" and v.get("sampleGranular"):
        source = "sample (granular)"

    hz = v.get("hz")
    if wave_raw in ("whiteNoise", "white_noise", "pinkNoise", "pink_noise", "noise", "granular") and not v.get(
        "bundledSampleName"
    ):
        note_cell = pan_label(v.get("pan", 0))  # no pitch on pure noise
    elif hz is None:
        note_cell = pan_label(v.get("pan", 0))
    else:
        note_cell = f"{hz_to_note(hz)}, {pan_label(v.get('pan', 0))}"

    highlights = []

    amp = v.get("amp")
    if amp is not None and abs(amp - 0.5) > 0.05:
        highlights.append(f"amp {amp:.2f}")

    drive = v.get("drive")
    if drive is not None and abs(drive - 1.0) > 0.05:
        highlights.append(f"drive {drive:.2f}×")

    f = v.get("filter")
    if f:
        ftype = f["type"]
        # Normalize lp/hp/bp short names
        ftype_short = {"lowpass": "LP", "highpass": "HP", "bandpass": "BP"}.get(ftype, ftype.upper())
        highlights.append(f"{ftype_short} {f['cutoffHz']:.0f} Hz Q {f['q']:.2f}")

    r = v.get("reverb")
    if r and r.get("mix", 0) > 0.04:
        highlights.append(f"reverb {r['decaySec']:.1f}s @ {r['mix']:.2f}")

    d = v.get("delay")
    if d and d.get("mix", 0) > 0.04:
        highlights.append(f"delay {d['timeSec']:.2f}s fb {d['feedback']:.2f} @ {d['mix']:.2f}")

    g = v.get("grain")
    if g and (abs(g["sizeMs"] - 80) > 5 or abs(g["densityHz"] - 8) > 0.5):
        highlights.append(f"grain {g['sizeMs']:.0f} ms @ {g['densityHz']:.2f}/s")

    timing = []
    sd = v.get("startDelaySec") or 0
    pd = v.get("playDurationSec") or 0
    rc = v.get("replayCount")
    if sd > 0:
        timing.append(f"start {int(sd)} s")
    if pd > 0:
        timing.append(f"play {int(pd)} s")
    if rc is not None:
        if rc == 0:
            timing.append("∞ replay")
        elif rc > 1:
            timing.append(f"× {rc} replay")
    if timing:
        highlights.append(" / ".join(timing))

    return [f"OSC {idx + 1}", source, note_cell, ", ".join(highlights) if highlights else "—"]


def slugify(s):
    return re.sub(r"[^a-z0-9]+", "-", s.lower()).strip("-")


def render_preset(p, curated):
    pid = slugify(p["name"])
    parts = [f'<article id="preset-{pid}" class="preset-entry">']
    badges = " ".join(
        f'<span class="platform-badge platform-{pf}">{pf}</span>' for pf in sorted(p.get("platforms", []))
    )
    parts.append(f'<h4>{html_mod.escape(p["name"])} {badges}</h4>')
    if p.get("subtitle"):
        parts.append(f'<p class="preset-subtitle">{html_mod.escape(p["subtitle"])}</p>')

    # Curated narrative (Drone Artists especially) — appears above the table.
    note = curated.get(p["name"])
    if note:
        parts.append(f'<div class="preset-curated">{note}</div>')

    voices = p.get("voices", [])
    if voices:
        parts.append('<table class="preset-voices">')
        parts.append("<tr><th>OSC</th><th>Source</th><th>Note / Pan</th><th>Highlights</th></tr>")
        for i, v in enumerate(voices[:4]):
            row = voice_row(v, i)
            parts.append(
                "<tr>" + "".join(f"<td>{html_mod.escape(str(c))}</td>" for c in row) + "</tr>"
            )
        parts.append("</table>")

    parts.append("</article>")
    return "\n".join(parts)


PAGE_HEAD = """<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8" />
<meta name="viewport" content="width=device-width, initial-scale=1, viewport-fit=cover" />
<title>Drone Meditations — Preset Reference</title>
<link rel="icon" type="image/svg+xml" href="data:image/svg+xml,%3Csvg xmlns='http://www.w3.org/2000/svg' viewBox='0 0 64 64'%3E%3Crect width='64' height='64' rx='12' fill='%23000'/%3E%3Ccircle cx='32' cy='32' r='18' fill='none' stroke='%23fff' stroke-width='2' opacity='0.85'/%3E%3Ccircle cx='32' cy='32' r='10' fill='none' stroke='%23fff' stroke-width='2' opacity='0.65'/%3E%3Ccircle cx='32' cy='32' r='3' fill='%23fff'/%3E%3C/svg%3E" />
<style>
  :root { --accent: #8fb9d9; --accent-2: #cfb6ea; --ink: #f0f0f0; --muted: rgba(255,255,255,0.65); --bg: #050505; }
  * { box-sizing: border-box; }
  body { background: var(--bg); color: var(--ink); font-family: -apple-system, BlinkMacSystemFont, "SF Pro", system-ui, sans-serif; line-height: 1.55; padding: 24px; max-width: 1000px; margin: 0 auto; font-size: 15px; }
  h1 { font-size: 30px; margin: 24px 0 8px; letter-spacing: -0.01em; }
  h2 { font-size: 22px; margin: 44px 0 16px; padding-bottom: 8px; border-bottom: 1px solid rgba(255,255,255,0.12); color: var(--accent); }
  h4 { margin: 22px 0 4px; font-size: 16px; font-weight: 600; }
  p.lede { color: var(--muted); margin-top: 0; }
  .preset-entry { margin-bottom: 26px; padding: 14px 18px; border-radius: 10px; background: rgba(255,255,255,0.03); border: 1px solid rgba(255,255,255,0.07); }
  .preset-subtitle { color: var(--muted); font-size: 13.5px; margin: 4px 0 10px; font-style: italic; }
  .preset-curated { color: var(--ink); font-size: 14px; margin: 8px 0 14px; padding: 10px 14px; background: rgba(207,182,234,0.05); border-left: 3px solid var(--accent-2); border-radius: 4px; }
  .preset-voices { width: 100%; border-collapse: collapse; font-size: 13px; margin-top: 8px; }
  .preset-voices th { text-align: left; color: var(--accent); padding: 6px 10px; border-bottom: 1px solid rgba(255,255,255,0.16); font-weight: 600; font-size: 11px; text-transform: uppercase; letter-spacing: 0.06em; }
  .preset-voices td { padding: 7px 10px; border-bottom: 1px solid rgba(255,255,255,0.05); vertical-align: top; }
  .preset-voices td:first-child { color: var(--accent); font-weight: 600; white-space: nowrap; width: 60px; }
  .platform-badge { display: inline-block; font-size: 10px; padding: 1px 7px; border-radius: 4px; margin-left: 4px; font-weight: 700; text-transform: uppercase; letter-spacing: 0.05em; vertical-align: 2px; }
  .platform-ios { background: rgba(143,185,217,0.20); color: var(--accent); }
  .platform-web { background: rgba(207,182,234,0.20); color: var(--accent-2); }
  .toc { background: rgba(255,255,255,0.04); padding: 14px 18px; border-radius: 10px; margin: 24px 0 36px; }
  .toc-entry { display: inline-block; margin-right: 14px; margin-bottom: 4px; }
  a { color: var(--accent); text-decoration: none; }
  a:hover { text-decoration: underline; }
  .back-link { display: inline-block; margin: 16px 0; color: var(--muted); font-size: 14px; }
  .meta { color: var(--muted); font-size: 13px; margin: 0 0 8px; }
</style>
</head>
<body>
<a href="./manual.html" class="back-link">← Back to manual</a>
<h1>Preset reference</h1>
<p class="lede">Auto-generated summary of every built-in preset that ships in the app. Tap a preset name in the app to load it; this page describes what's inside — voices, FX highlights, timing envelopes, and (for the Drone Artists category) curated artistic context.</p>
<p class="meta">Each row is one voice. <em>Source</em> is the waveform or sample. <em>Highlights</em> lists non-default amp / drive / filter / reverb / delay / grain / timing values — defaults are omitted to keep the table scannable. Pitches are shown as both note name and Hz so they read in any tuning system.</p>
"""

PAGE_FOOT = '<a href="./manual.html" class="back-link">← Back to manual</a>\n</body>\n</html>'


def render_html(presets, curated):
    by_cat = {}
    for p in presets:
        cat = p.get("category_display", p.get("category", "Other"))
        by_cat.setdefault(cat, []).append(p)
    # Sort each cat alphabetically by name, except Setup (single).
    for cat in by_cat:
        by_cat[cat].sort(key=lambda p: p["name"])

    cats_present = [c for c in CAT_ORDER if c in by_cat] + [c for c in by_cat if c not in CAT_ORDER]

    parts = [PAGE_HEAD]

    parts.append('<div class="toc"><strong>Jump to:</strong> ')
    for cat in cats_present:
        cid = slugify(cat)
        parts.append(
            f'<span class="toc-entry"><a href="#cat-{cid}">{html_mod.escape(cat)} ({len(by_cat[cat])})</a></span>'
        )
    parts.append("</div>")

    for cat in cats_present:
        cid = slugify(cat)
        parts.append(f'<section><h2 id="cat-{cid}">{html_mod.escape(cat)}</h2>')
        for p in by_cat[cat]:
            parts.append(render_preset(p, curated))
        parts.append("</section>")

    parts.append(PAGE_FOOT)
    return "\n".join(parts)


def main():
    ios = parse_ios_presets()
    web = parse_web_presets()
    presets = merge_presets(ios, web)

    curated = {}
    if CURATED_JSON.exists():
        try:
            curated = json.loads(CURATED_JSON.read_text())
        except Exception as e:
            print(f"⚠️  could not parse curated JSON: {e}")

    out = render_html(presets, curated)
    OUT_FILE.write_text(out)
    print(f"📄 wrote {OUT_FILE.relative_to(ROOT)}")
    print(f"   iOS: {len(ios)}, web: {len(web)}, unique: {len(presets)}, curated notes: {len(curated)}")


if __name__ == "__main__":
    main()
