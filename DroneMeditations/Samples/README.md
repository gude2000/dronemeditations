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
as the picker's section label. Current bundle layout:

```
Samples/
  Acoustic/        — guitar, piano, organ, voice
  Atmospheric/     — ambient pads, drones, sustained beds
  Cosmic/          — planet tones, space ambience
  Field/           — rain / wind / surf / birds / storms
  Instruments/     — bagpipe, bansuri, shakuhachi, chord layers
  Urban/           — city, day ambience
  User samples/    — empty slot for maintainer additions (pre-build)
```

Flat structure (files directly in `Samples/`) lands under a single
"Samples" header.

## "User samples" — two paths to the same picker section

There are two places audio files can land in the "User samples"
category at runtime:

1. **Pre-build (maintainer)**: drop files into
   `DroneMeditations/Samples/User samples/` here in the project.
   They ship inside the .ipa and appear immediately on install.
2. **Runtime (end user)**: the app exposes its container to the iOS
   Files app (`UIFileSharingEnabled` + `LSSupportsOpeningDocumentsInPlace`
   in Info.plist), with a pre-created `Documents/User samples/`
   folder + README inside. Anything users drop there via Files /
   AirDrop / share-sheet appears in the same "User samples" picker
   section on the next picker open — no app restart.

`BundledSampleStore` reads both sources every time the picker opens
and merges them into one "User samples" entry. The bundle scan is
memoized (it doesn't change at runtime); the Documents scan is
fresh on every access.

## Tips

- **Length**: 4–10 seconds loops cleanly. Longer is fine; it
  increases the app bundle size.
- **Format**: WAV / AIF for uncompressed, M4A or MP3 for compressed.
  CAF is great for shipping with iOS — same fidelity as WAV, smaller
  metadata overhead.
- **Bundle weight**: every file lives in the .ipa shipped to App Store.
  Keep the total under ~50 MB or the download size will get hefty.
