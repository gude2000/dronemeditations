# iOS bundled samples

Drop audio files (`.wav`, `.mp3`, `.m4a`, `.aac`, `.aif`/`.aiff`,
`.caf`) into this folder and they'll appear in the **Bundled** picker
that opens when you tap **Load file…** on an oscillator strip.

This folder is registered in the Xcode project as a **folder
reference** (NOT a group). That means files added here get bundled
automatically on the next build — no Xcode edits needed.

## If you re-create the project from scratch

The folder-reference wiring is in `project.pbxproj`:

- A `PBXFileReference` with `lastKnownFileType = folder` pointing at
  this directory.
- A matching `PBXBuildFile` and `PBXResourcesBuildPhase` entry so the
  folder ships as a bundle resource.

If you ever lose those entries (e.g. a manual project regeneration),
re-add by dragging this folder into the Xcode project navigator and
choosing **Create folder references** (NOT "Create groups") with the
DroneMeditations target checked.

## Sub-folder grouping

`BundledSampleStore` reads the first path component under `Samples/`
as the picker's section label. If you organize:

```
Samples/
  Drones/
    phi-drone.mp3
  Themes/
    sable.mp3
```

…the picker shows "Drones" and "Themes" headers. Flat structure (no
subfolders) shows everything under a single "Samples" header.

## Tips

- **Length**: 4–10 seconds loops cleanly. Longer is fine; it
  increases the app bundle size.
- **Format**: WAV / AIF for uncompressed, M4A or MP3 for compressed.
  CAF is great for shipping with iOS — same fidelity as WAV, smaller
  metadata overhead.
- **Bundle weight**: every file lives in the .ipa shipped to App Store.
  Keep the total under ~50 MB or the download size will get hefty.
