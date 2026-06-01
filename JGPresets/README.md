# JG Presets — Developer Patches drop-in

This folder is the staging area for the four named JG presets (and any
others Jose adds later) that ship in the **Developer Patches** category.

## What goes here

Drop **`.dronepreset`** files (the JSON format we already round-trip
between iOS and web — see `web/js/preset-sharing.js` and
`DroneMeditations/Audio/UserPresetStore.swift`) into this folder.

Target set:

- `JG Ondulations.dronepreset`
- `JG Dub Wave.dronepreset`
- `JG Freedom Did Not Lose.dronepreset`
- `JG Piano Repetition.dronepreset`

## Workflow

1. **Export from web** (`dronemeditations.com`) or AirDrop from the iOS
   app — either path yields a self-contained `.dronepreset` file with
   embedded WAV samples.
2. **Drop the file in this folder.** The filename becomes the preset's
   display name (minus the `.dronepreset` extension).
3. **Tell Claude** ("convert the new JG presets" or similar). The
   conversion step will:
   - Read each envelope's JSON.
   - Extract any embedded WAV samples into
     `DroneMeditations/Samples/Developer/` so they ship with the app.
   - Generate a `Preset` entry in `DroneMeditations/Models/Preset.swift`
     under the `.developerPatches` category, slotted at the top of the
     Developer Patches block (above the 10 procedurally-designed JG
     patches).
   - Mirror the harmonic / envelope character to `web/js/music.js`. Web
     uses the granular-noise mode in place of bundled samples because
     web's built-in preset apply doesn't yet honor `bundledSampleName`
     on built-ins (separate task).

## Notes

- The four named presets are author-curated artistic statements — Claude
  doesn't try to "improve" them on conversion, just transcribes them.
- Samples extracted here go to `DroneMeditations/Samples/Developer/`
  rather than the existing category subfolders so they're easy to
  identify as part of the JG drop.
- The 10 procedurally-designed JG patches that ship alongside live
  inline in `Preset.swift` — no files needed.
