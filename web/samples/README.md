# Bundled samples

Audio files dropped in this folder are served by the web app at
`https://dronemeditations.com/samples/<filename>`. They appear in the
"Bundled samples" picker that opens when you click **Load file…** on any
oscillator strip — pick one with a tap and it loads directly, no upload
dialog required.

## Adding a sample

1. Copy your audio file into this folder (`web/samples/`). Supported
   formats: WAV, MP3, OGG, FLAC. Mono or stereo, any sample rate
   (the engine resamples).
2. Add an entry to `index.json` with the file name + a display name
   and (optionally) a category for grouping:

   ```json
   {
     "samples": [
       { "file": "tibetan-bowl.wav", "name": "Tibetan Bowl", "category": "Singing bowls" },
       { "file": "wind.ogg",         "name": "Mountain Wind",  "category": "Field" }
     ]
   }
   ```

3. Commit + push. The app fetches `index.json` on load — once the new
   deploy is live, the file appears in the picker.

## Why a manifest?

Browsers can't enumerate the contents of a static folder over HTTP
(no `ls` over the web). The manifest is how we tell the app which
files are present.

## Sizes & limits

- Keep individual files under ~5 MB so they load quickly. Long pads
  loop cleanly — 4–10 seconds is plenty.
- The whole `samples/` folder is part of the GitHub Pages deploy, so
  keep the total under ~50 MB to stay friendly with the page weight.

## Privacy

These files are shipped to every visitor. Don't put anything copyrighted
that you don't have rights to redistribute, or anything personal.
