#!/usr/bin/env python3
"""
Generate Swift Preset entries from _summary.json for the four
named JG presets (Ondulations, Dub Wave, Whole Tone Wind,
Interrupted). Skips Scriabin Rain + Underwater for now — their
samples are 24-25 MB each and we want a conversation about
trim/downsample before bundling.

Writes to JGPresets/_generated_presets.swift — paste-ready
block. Each preset entry is hand-checked-shape, not just blind
JSON dump, so it reads naturally in Preset.swift.
"""
import json, pathlib

ROOT = pathlib.Path(__file__).resolve().parent.parent
SUMMARY = ROOT / "JGPresets" / "_summary.json"
OUT = ROOT / "JGPresets" / "_generated_presets.swift"

# Preset names we want to bundle this turn. The two huge ones
# (Scriabin Rain 24+15 MB, Underwater 24 MB) we'll handle after a
# conversation about trim/downsample. JG JoG is the latest add
# (Jun 2026); ~9.5 MB sample, ships under Developer Patches.
INCLUDE = {"JG Dub Wave", "JG Interrupted", "JG Ondulations", "JG Whole Tone Wind", "JG JoG"}

# Per-preset subtitle (curated, not auto-generated).
SUBTITLES = {
    "JG Dub Wave":         "Author recording · dubwise low end · Replay × 5 motion",
    "JG Interrupted":      "Vocal granular at high pos jitter · pulsing delay · Aeolian",
    "JG Ondulations":      "Author recording · undulating sample-granular cloud",
    "JG Whole Tone Wind":  "Whole-tone stack · sample granular wind · Replay × 5",
    "JG JoG":              "Author recording · JoG sample-granular study",
}

def fmt(x, places=2):
    """Format a Double for Swift, dropping trailing zeros where natural."""
    if x is None:
        return "0"
    if isinstance(x, int):
        return str(x)
    if isinstance(x, float):
        if x.is_integer():
            return f"{x:.1f}"   # always at least one decimal to read as Double
        return f"{x:.{places}f}"
    return str(x)

def voice_lines(idx, v):
    """Render one Voice(...) call. Only emit fields whose values differ
    from the Voice init default (or are required: hz / pan)."""
    parts = [f"hz: {fmt(v['frequencyHz'])}", f"pan: {fmt(v.get('pan',0))}"]
    wave = v.get("waveform") or "sine"
    # Always emit so loading the preset on a strip currently set to a
    # different wave (sample / granular / etc.) resets cleanly.
    parts.append(f'wave: .{wave}')

    amp = v.get("amplitude")
    if amp is not None and amp != 0.5:
        parts.append(f"amp: {fmt(amp)}")

    drive = v.get("drive")
    if drive is not None and abs(drive - 1.0) > 1e-3:
        parts.append(f"drive: {fmt(drive)}")

    sd = v.get("startDelaySec") or 0
    if sd > 0: parts.append(f"startDelaySec: {int(sd) if sd == int(sd) else fmt(sd)}")
    pd = v.get("playDurationSec") or 0
    if pd > 0: parts.append(f"playDurationSec: {int(pd) if pd == int(pd) else fmt(pd)}")
    rc = v.get("replayCount")
    if rc is not None and rc != 1: parts.append(f"replayCount: {rc}")

    flt = v.get("filter")
    if flt:
        ftype = flt.get("type","lowpass")
        # Only emit if not (lowpass, ~4000, ~0.7) which is the default
        is_default = (ftype == "lowpass"
                      and abs(flt.get("cutoffHz",4000) - 4000) < 1
                      and abs(flt.get("q",0.7) - 0.7) < 1e-3)
        if not is_default:
            parts.append(
                f'filter: FilterState(type: .{ftype}, cutoffHz: {fmt(flt["cutoffHz"],0)}, q: {fmt(flt["q"])})'
            )

    rev = v.get("reverb")
    if rev:
        decay = rev.get("decaySec",2.0); mix = rev.get("mix",0.0)
        # Default ReverbState() = decaySec=2.0, mix=0.0. Skip if default-ish.
        if not (abs(decay - 2.0) < 1e-3 and mix < 1e-3):
            parts.append(f'reverb: ReverbState(decaySec: {fmt(decay)}, mix: {fmt(mix)})')

    dly = v.get("delay")
    if dly:
        tm = dly.get("timeSec",0.3); fb = dly.get("feedback",0.4); mx = dly.get("mix",0.0)
        if not (abs(tm - 0.3) < 1e-3 and abs(fb - 0.4) < 1e-3 and mx < 1e-3):
            parts.append(
                f'delay: DelayState(timeSec: {fmt(tm)}, feedback: {fmt(fb)}, mix: {fmt(mx)})'
            )

    ch = v.get("chorus")
    if ch:
        # Default ChorusState rate=0.5, depth=0.5, width=0.5, mix=0.0
        rate = ch.get("rateHz", 0.5); depth = ch.get("depth", 0.5)
        width = ch.get("width", 0.5); mix = ch.get("mix", 0.0)
        if mix > 1e-3 or abs(rate - 0.5) > 0.05 or abs(depth - 0.5) > 0.05 or abs(width - 0.5) > 0.05:
            parts.append(
                f'chorus: ChorusState(rateHz: {fmt(rate)}, depth: {fmt(depth)}, width: {fmt(width)}, mix: {fmt(mix)})'
            )

    gr = v.get("grain")
    if gr:
        sz = gr.get("sizeMs", 80); d = gr.get("densityHz", 8)
        j = gr.get("jitter", 0.6); ps = gr.get("panSpread", 0.5)
        is_default = (abs(sz - 80) < 1 and abs(d - 8) < 0.1
                      and abs(j - 0.6) < 1e-3 and abs(ps - 0.5) < 1e-3)
        if not is_default:
            parts.append(
                f'grain: GrainState(sizeMs: {fmt(sz,0)}, densityHz: {fmt(d)}, jitter: {fmt(j)}, panSpread: {fmt(ps)})'
            )

    # bundled sample + granular
    bn = v.get("__bundledSampleName")
    if bn:
        parts.append(f'bundledSampleName: "{bn}"')
    if v.get("sampleGranular"):
        parts.append('sampleGranular: true')
    pf = v.get("grainSamplePosFrac")
    if pf is not None and abs(pf - 0.5) > 0.01:
        parts.append(f'grainSamplePosFrac: {fmt(pf)}')
    pj = v.get("grainSamplePosJitter")
    if pj is not None and abs(pj - 0.2) > 0.01:
        parts.append(f'grainSamplePosJitter: {fmt(pj)}')

    return f"Voice(\n    {',\n    '.join(parts)}\n)"

def main():
    with open(SUMMARY) as f:
        data = json.load(f)

    lines = ["        // ── JG named presets (author-curated) ──\n"]
    for p in data:
        name = p["name"]
        if name not in INCLUDE:
            continue
        sub = SUBTITLES.get(name, "Author-curated patch")
        lines.append(f'        Preset("{name}", .developerPatches,')
        lines.append(f'               subtitle: "{sub}", [')
        for i, v in enumerate(p["voices"]):
            vc = voice_lines(i, v)
            vc = "                " + vc.replace("\n", "\n                ")
            comma = "," if i < len(p["voices"]) - 1 else ""
            lines.append(f"{vc}{comma}")
        lines.append("               ]),\n")

    with open(OUT, "w") as f:
        f.write("\n".join(lines))
    print(f"📄 wrote {OUT.relative_to(ROOT)}  ({len(INCLUDE)} presets)")

if __name__ == "__main__":
    main()
