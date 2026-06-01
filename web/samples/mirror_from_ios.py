#!/usr/bin/env python3
"""
Mirror DroneMeditations/Samples/ → web/samples/ and regenerate
web/samples/index.json from the resulting file tree.

Usage:
    python3 web/samples/mirror_from_ios.py [--exclude-larger-than MB]

By default copies every audio file regardless of size. Pass
--exclude-larger-than 20 to skip files over 20 MB (useful before
heavy commits if you want to keep the static-site bundle small).

Run this whenever you add / remove samples on iOS and want web to
match. Idempotent — re-copies existing files only if their size
differs (cheap sanity check). Manifest is rewritten every time.
"""
import argparse, json, pathlib, shutil

ROOT = pathlib.Path(__file__).resolve().parent.parent.parent
IOS_SAMPLES = ROOT / "DroneMeditations" / "Samples"
WEB_SAMPLES = ROOT / "web" / "samples"
DISPLAY_NAMES_FILE = WEB_SAMPLES / "display_names.json"

# Audio extensions the web engine can decode (decodeAudioData).
AUDIO_EXTS = {".wav", ".mp3", ".m4a", ".aac", ".ogg", ".flac", ".aif", ".aiff"}

# Folders inside iOS Samples/ that ARE bundled. "User samples" is a
# runtime drop location for the user via the Files app — not bundled
# content, skip it.
INCLUDE_CATEGORIES = {
    "Acoustic", "Atmospheric", "Cosmic", "Developer",
    "Field", "Instruments", "Urban",
}

def load_display_overrides() -> dict[str, str]:
    """Read display_names.json if present. Returns a stem → pretty-name
    map. Missing file → empty dict (script still runs)."""
    if not DISPLAY_NAMES_FILE.exists():
        return {}
    try:
        with open(DISPLAY_NAMES_FILE) as f:
            data = json.load(f)
        return data.get("overrides", {}) or {}
    except (json.JSONDecodeError, OSError) as e:
        print(f"   ⚠  couldn't read {DISPLAY_NAMES_FILE.name}: {e}")
        return {}

def pretty_name(stem: str, overrides: dict[str, str]) -> str:
    """Compute the display name for a file stem.
       1. explicit override from display_names.json (wins)
       2. all-lowercase + has hyphens → Title Case (so 'phi-drone'
          becomes 'Phi Drone')
       3. otherwise pass through (already-pretty names like
          'Bansuri B2' or 'Calm Sea' stay as-is)."""
    if stem in overrides:
        return overrides[stem]
    if stem.islower() and "-" in stem:
        return stem.replace("-", " ").title()
    return stem

def main():
    p = argparse.ArgumentParser()
    p.add_argument("--exclude-larger-than", type=float, default=None,
                   metavar="MB",
                   help="skip files over this size; default copies everything")
    args = p.parse_args()

    if not IOS_SAMPLES.exists():
        print(f"✗ iOS samples folder not found at {IOS_SAMPLES}")
        return 1

    # ── Sync files ──────────────────────────────────────────
    copied = 0
    skipped_size = 0
    seen_web: set[pathlib.Path] = set()  # relative paths we wrote, for cleanup

    for cat in sorted(IOS_SAMPLES.iterdir()):
        if not cat.is_dir() or cat.name not in INCLUDE_CATEGORIES:
            continue
        dest_cat = WEB_SAMPLES / cat.name
        dest_cat.mkdir(parents=True, exist_ok=True)
        for f in sorted(cat.iterdir()):
            if not f.is_file() or f.suffix.lower() not in AUDIO_EXTS:
                continue
            size_mb = f.stat().st_size / (1024 * 1024)
            if args.exclude_larger_than is not None and size_mb > args.exclude_larger_than:
                print(f"   ⏭  skip {f.name}  ({size_mb:.1f} MB > {args.exclude_larger_than})")
                skipped_size += 1
                continue
            dest_file = dest_cat / f.name
            rel = dest_file.relative_to(WEB_SAMPLES)
            seen_web.add(rel)
            # Only copy if missing or size differs (cheap sanity).
            if dest_file.exists() and dest_file.stat().st_size == f.stat().st_size:
                continue
            shutil.copy2(f, dest_file)
            print(f"   ✓ copy {rel}  ({size_mb:.2f} MB)")
            copied += 1

    # ── Clean up: remove files in INCLUDE_CATEGORIES that no longer
    # exist in iOS. Skip files in the root and unknown subfolders so
    # we don't nuke legacy/manual content. ────────────────────────
    for cat_name in INCLUDE_CATEGORIES:
        web_cat = WEB_SAMPLES / cat_name
        if not web_cat.exists():
            continue
        for f in web_cat.iterdir():
            if not f.is_file() or f.suffix.lower() not in AUDIO_EXTS:
                continue
            rel = f.relative_to(WEB_SAMPLES)
            if rel not in seen_web:
                f.unlink()
                print(f"   ✗ drop {rel} (not in iOS)")

    # ── Regenerate manifest ─────────────────────────────────
    display_overrides = load_display_overrides()
    samples_entries = []
    for cat_name in sorted(INCLUDE_CATEGORIES):
        web_cat = WEB_SAMPLES / cat_name
        if not web_cat.exists():
            continue
        for f in sorted(web_cat.iterdir()):
            if not f.is_file() or f.suffix.lower() not in AUDIO_EXTS:
                continue
            rel_for_json = f"{cat_name}/{f.name}"
            display = pretty_name(f.stem, display_overrides)
            samples_entries.append({
                "file": rel_for_json,
                "name": display,
                "category": cat_name,
            })

    manifest = {
        "_comment": (
            "List of bundled sample audio files. Each entry needs file "
            "(relative to this folder), name (shown in the picker), "
            "and optional category. Auto-generated by "
            "mirror_from_ios.py — don't hand-edit; instead drop files "
            "into DroneMeditations/Samples/<Category>/ and re-run the "
            "script. Supported formats: WAV / MP3 / OGG / FLAC / AIF / "
            "M4A / AAC."
        ),
        "_addInstructions": (
            "1) Drop your file into DroneMeditations/Samples/<Category>/  "
            "2) Run  python3 web/samples/mirror_from_ios.py  "
            "3) Commit (web/samples/ + manifest update together)."
        ),
        "samples": samples_entries,
    }
    out = WEB_SAMPLES / "index.json"
    with open(out, "w") as f:
        json.dump(manifest, f, indent=2, ensure_ascii=False)
    total_size = sum(
        (WEB_SAMPLES / e["file"]).stat().st_size for e in samples_entries
    ) / (1024 * 1024)
    print(f"\n📄 wrote {out.relative_to(ROOT)}")
    print(f"   {len(samples_entries)} entries, ~{total_size:.1f} MB total")
    if skipped_size:
        print(f"   {skipped_size} files skipped (size cap)")
    return 0

if __name__ == "__main__":
    raise SystemExit(main())
