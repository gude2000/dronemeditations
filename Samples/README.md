# Samples — drop audio files here

Two destinations depending on which app you want them in:

| Where to put the file       | Surfaces in which app                                                        |
| --------------------------- | ---------------------------------------------------------------------------- |
| `web/samples/`              | Web app's **Load file…** picker (also update `web/samples/index.json`)       |
| `DroneMeditations/Samples/` | iOS app's **Load file…** picker (added to the app bundle as a folder reference) |

Both folders share the same conventions:

- **Formats**: WAV, MP3, OGG, FLAC. Mono or stereo. The engine resamples
  any input rate.
- **Length**: 4–10 seconds is the sweet spot. The engine loops the file
  seamlessly when a sample voice is held.
- **Size**: keep individual files under ~5 MB. The whole `web/samples/`
  folder is part of the GitHub Pages deploy, so total under ~50 MB.

## Web details

See `web/samples/README.md` for the manifest (`index.json`) format —
browsers can't enumerate a static folder, so the app needs the file
list explicitly.

## iOS details

Files added to `DroneMeditations/Samples/` need to be referenced in the
Xcode project (Add Files → check "Create folder references" so it stays
a single bundle resource). The app scans the bundle's `Samples`
subfolder at launch and surfaces every audio file it finds in the
**Bundled samples** picker.
