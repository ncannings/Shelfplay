# ShelfPlay for iPhone

A native SwiftUI version of ShelfPlay. Scan a record's barcode or photograph its cover, then play it on **Apple Music** or **Spotify**.

## What's different from the web app

| | Web app | iPhone app |
|---|---|---|
| Cover recognition | Google Gemini (your API key) | **On-device**: Vision + Apple Intelligence. No API key, nothing leaves the phone |
| Apple Music | — | Barcode/UPC lookup, plays inside the app (subscription) or opens Music |
| Spotify | Server-side token exchange | PKCE directly with Spotify (no client secret, no server) |
| Barcode lookup | Spotify UPC, MusicBrainz, Discogs | Spotify UPC, **Apple Music UPC**, MusicBrainz |
| Library | localStorage | SwiftData, same JSON shape, so family sync works across web and iOS |

### How cover matching works

1. **Vision** finds the sleeve in the photo, flattens it, reads its text and computes a visual feature print.
2. Covers already on your shelf are recognised instantly by feature-print distance.
3. **Apple Intelligence** (Foundation Models, on-device) turns the noisy OCR into artist/title hypotheses. It ignores labels, catalogue numbers and stickers, fixes OCR misspellings, and handles self-titled albums.
4. Hypotheses are searched in Apple Music (and Spotify, if connected).
5. Candidates are re-ranked by agreement with the printed text and by how closely their artwork matches your photo. Runners-up are offered under "Not this one?".

Without Apple Intelligence (iOS 18–25, older iPhones, or when it's turned off), step 3 falls back to a heuristic based on text size. Covers with no text at all can only be matched if they're already on your shelf; use the barcode or search for those.

## Requirements

- Xcode 26+, iOS 18+
- Apple Intelligence (iOS 26, iPhone 15 Pro or later) for the best cover matching; older iPhones use a text-size heuristic
- Spotify connect is hidden until unlocked with the worker's `ADMIN_CODE` (tap the version number in Settings 5 times): Spotify's development mode allows only 5 accounts

## Setup

1. Copy the config template:
   ```bash
   cp Support/Secrets.example.xcconfig Support/Secrets.xcconfig
   ```
2. In `Secrets.xcconfig`, set `DEVELOPMENT_TEAM` and a `SHELFPLAY_BUNDLE_ID` you own.
3. **Apple Music:** at developer.apple.com › Identifiers, open the App ID and enable **MusicKit** under App Services. Catalogue playback needs this.
4. **Spotify (optional):** add `shelfplay://callback` as a Redirect URI on your Spotify app, then set `SPOTIFY_CLIENT_ID`, or set `SHELFPLAY_API_HOST` so the app fetches it from your worker's `/api/config`.
5. **Family shelf (optional):** set `SHELFPLAY_API_HOST` to your ShelfPlay worker host.
6. Open `ShelfPlay.xcodeproj` and run on a device.

`Secrets.xcconfig` is gitignored. The app builds and runs with every value blank. Spotify and family sync stay disabled until they're configured.

## Simulator notes

The simulator has no camera. Use the photo button or Search. Vision feature prints don't run in the simulator (no Neural Engine), so artwork comparison only takes effect on a device. OCR and Apple Intelligence work in the simulator if your Mac has Apple Intelligence on.

Debug builds accept launch arguments for headless testing:
`-ShelfPlayCoverTest /path/to/photo.jpg` and `-ShelfPlayBarcodeTest 075992731324`.
