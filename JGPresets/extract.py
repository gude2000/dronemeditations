#!/usr/bin/env python3
"""
Extract .dronepreset envelopes into:
  - DroneMeditations/Samples/Developer/<canonical>.wav  (one per UNIQUE sample,
                                                          deduped by sha256)
  - JGPresets/_summary.json                              (preset metadata
                                                          + bundledSampleName
                                                          assignments)

Sample naming:
  • The originator preset's base name gives the canonical name for each
    unique sample (first preset that introduced it owns the name).
  • If a single preset introduces multiple unique samples, suffixes -2,
    -3 etc. are appended.

Run once after dropping new .dronepreset files into JGPresets/.
"""
import argparse, base64, hashlib, json, pathlib, sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
PRESETS_DIR = ROOT / "JGPresets"
SAMPLES_DIR = ROOT / "DroneMeditations" / "Samples" / "Developer"

def main():
    p = argparse.ArgumentParser()
    p.add_argument("--max-mb", type=float, default=60.0)
    args = p.parse_args()

    SAMPLES_DIR.mkdir(parents=True, exist_ok=True)
    # hash → canonical name (first preset's base name)
    sample_canonical: dict[str, str] = {}
    # canonical name → bytes (written once)
    written: set[str] = set()
    summary = []

    for fp in sorted(PRESETS_DIR.glob("*.dronepreset")):
        size_mb = fp.stat().st_size / (1024 * 1024)
        if size_mb > args.max_mb:
            print(f"⏭  SKIP  {fp.name}  ({size_mb:.1f} MB > {args.max_mb} MB)")
            continue
        print(f"→  read  {fp.name}  ({size_mb:.1f} MB)")
        with open(fp, "r") as f:
            env = json.load(f)

        base_name = fp.stem
        preset = env.get("preset", {})

        # Walk samples in the envelope; assign canonical name by content
        # hash. id_to_canonical lets us re-map sampleRef.id → bundledSampleName
        # when generating voice configs.
        id_to_canonical: dict[str, str] = {}
        local_count = 0
        for s in (env.get("samples", []) or []):
            data_b64 = s.get("data")
            sid = s.get("filename")
            if not data_b64 or not sid:
                continue
            bytes_ = base64.b64decode(data_b64)
            h = hashlib.sha256(bytes_).hexdigest()
            mime = (s.get("mime") or "audio/wav").lower()
            ext = "wav" if "wav" in mime else ("mp3" if "mp3" in mime else "wav")
            if h in sample_canonical:
                canonical = sample_canonical[h]
                print(f"   ↺ dedupe {sid[:20]}… → {canonical}  ({len(bytes_)/1024:.0f} KB saved)")
            else:
                # First time we see this content. Name it after the preset
                # (with a suffix if the preset already named one).
                local_count += 1
                canonical = base_name if local_count == 1 else f"{base_name}-{local_count}"
                sample_canonical[h] = canonical
                out_path = SAMPLES_DIR / f"{canonical}.{ext}"
                if canonical not in written:
                    with open(out_path, "wb") as out:
                        out.write(bytes_)
                    written.add(canonical)
                    print(f"   ✓ wrote {out_path.relative_to(ROOT)}  ({len(bytes_)/1024:.0f} KB)")
            id_to_canonical[sid] = canonical

        # Transform voices — replace sampleRef.id (or sampleStoredFilename)
        # with bundledSampleName referencing the canonical sample.
        voices_out = []
        for v in (preset.get("oscillators") or []):
            stored = v.get("sampleStoredFilename")
            ref = v.get("sampleRef") or {}
            ref_id = ref.get("id")
            bundled_name = None
            if stored and stored in id_to_canonical:
                bundled_name = id_to_canonical[stored]
            elif ref_id and ref_id in id_to_canonical:
                bundled_name = id_to_canonical[ref_id]
            v_out = dict(v)
            if bundled_name:
                v_out["__bundledSampleName"] = bundled_name
            voices_out.append(v_out)

        summary.append({
            "file": fp.name,
            "name": preset.get("name"),
            "voices": voices_out
        })

    out = PRESETS_DIR / "_summary.json"
    with open(out, "w") as f:
        json.dump(summary, f, indent=2)
    total = sum(p.stat().st_size for p in SAMPLES_DIR.glob("*.wav"))
    print(f"\n📄 wrote {out.relative_to(ROOT)}")
    print(f"   {len(summary)} presets, {len(written)} unique samples, "
          f"{total/(1024*1024):.1f} MB total")

if __name__ == "__main__":
    main()
