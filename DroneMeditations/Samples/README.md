# iOS bundled samples

Drop audio files (`.wav`, `.mp3`, `.m4a`, `.aac`, `.aif`/`.aiff`,
`.caf`) into this folder and they'll appear in the **Bundled** picker
that opens when you tap **Load file…** on an oscillator strip.

## One-time Xcode setup

The folder needs to be referenced by the Xcode project as a **folder
reference** (blue folder icon) so files added later get bundled
automatically without re-editing the project.

In Xcode:
1. Drag the `Samples` folder from Finder into the project navigator.
2. Choose **Create folder references** (NOT "Create groups").
3. Make sure the **DroneMeditations** target is checked.

After that, any audio file dropped into this folder appears in the
in-app picker on the next build, no further Xcode steps needed.

## Tips

- **Length**: 4–10 seconds loops cleanly. Longer is fine; it
  increases the app bundle size.
- **Format**: WAV / AIF for uncompressed, M4A or MP3 for compressed.
  CAF is great for shipping with iOS — same fidelity as WAV, smaller
  metadata overhead.
- **Bundle weight**: every file lives in the .ipa shipped to App Store.
  Keep the total under ~50 MB or the download size will get hefty.
