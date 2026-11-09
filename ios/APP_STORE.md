# App Store submission — ShelfPlay

Everything needed to create the listing in App Store Connect. Copy is checked against Apple's character limits.

## App information

| Field | Value |
|---|---|
| Name | ShelfPlay |
| Subtitle (30) | Scan records, play instantly |
| Bundle ID | `stream.shelfplay.app` |
| Primary category | Music |
| Secondary category | Utilities |
| Price | Free |
| Age rating | 4+ (no objectionable content) |
| Marketing URL | https://shelfplay.stream/ |
| Support URL | https://shelfplay.stream/support |
| Privacy policy URL | https://shelfplay.stream/privacy |
| Copyright | 2026 Researchmatic Limited |

## Promotional text (170)

Point your iPhone at a vinyl record or CD — the barcode or the cover — and play it in a tap on Apple Music or Spotify. Cover recognition runs on your iPhone.

## Keywords (100)

```
vinyl,record,cd,lp,scanner,barcode,album,cover,collection,apple music,spotify,turntable,music
```

## Description

Your record shelf, ready to play.

ShelfPlay connects the records on your shelf to the music in your streaming app. Point your iPhone at a vinyl record, CD or cassette — the barcode or the cover — and ShelfPlay finds the album on Apple Music or Spotify so you can play it straight away.

SCAN THE BARCODE OR THE COVER
• Barcodes are read instantly and matched to the exact release.
• No barcode? Hold the sleeve in the square — ShelfPlay spots it and takes the picture when it's steady. Prefer the shutter? Switch to manual.

SMART, PRIVATE COVER RECOGNITION
• On iPhones with Apple Intelligence, an on-device model reads the sleeve and works out the artist and album — even with stylised lettering.
• Cover photos are processed on your iPhone. Nothing is sent to an AI service.

PLAY IT YOUR WAY
• With an Apple Music subscription, records play right inside ShelfPlay.
• Open any album in the Spotify app.
• Your disc, exactly: when a regional edition or compilation differs from the streaming album, ShelfPlay can play your disc's actual tracklist.

YOUR SHELF
• Every record you scan is saved to your shelf, searchable and sortable.
• Share a family shelf with your household using a simple code.

FREE, NO ACCOUNT
No sign-up, no ads, no tracking.

About Spotify: Spotify lets apps in development connect only five Spotify accounts. Direct playback to Spotify speakers and playlist building will open to everyone once ShelfPlay reaches the 250,000 monthly users Spotify requires. Opening albums in Spotify works for everyone today.

## What's New (1.0)

The first release of ShelfPlay for iPhone.

## App Privacy questionnaire

- **Do you or your third-party partners collect data from this app?** Yes — only for the optional family shelf.
- **Data type:** User Content › Other User Content (the album list of a family shelf).
  - Used for: App Functionality
  - Linked to the user's identity: **No** (stored under a random family code; no accounts)
  - Used for tracking: **No**
- Everything else: not collected. Camera images are processed on-device and never leave the phone. Catalogue searches go directly to Apple, MusicBrainz, Cover Art Archive and (if connected) Spotify; ShelfPlay doesn't store them.

The bundled `PrivacyInfo.xcprivacy` declares the same, plus the UserDefaults API reason `CA92.1`.

## Export compliance

`ITSAppUsesNonExemptEncryption = NO` is set in `Support/Info.plist` (HTTPS only), so no export question appears per build.

## App Review notes

```
ShelfPlay identifies physical music releases (vinyl, CD) from their barcode or cover and opens them in Apple Music or Spotify.

To test without physical records: tap Search on the scanner and type an album (e.g. "Fleetwood Mac Rumours") or a barcode (e.g. 075992731324). To test cover recognition, tap the photo button and choose any album cover image.

Cover recognition is on-device (Vision + Apple Intelligence Foundation Models on iOS 26; a text-size heuristic on iOS 18–25). No images are uploaded.

Apple Music: playback inside the app needs an Apple Music subscription; otherwise albums open in the Music app.

Spotify: connecting a Spotify account is intentionally limited to invited accounts (Spotify's developer-mode limit), so the Connect Spotify option is hidden for reviewers. "Open in Spotify" works without an account.

No login is required.
```

## Screenshots

Required: **6.9" iPhone** (1320 × 2868, portrait). Apple scales these for smaller iPhones. Suggested set, captured on a device:

1. Scanner in Cover mode with a sleeve in the square ("Hold steady…")
2. Result sheet — album identified, "Identified with Apple Intelligence", Play button
3. "Not this one?" alternatives
4. Shelf (library grid)
5. "Play your disc's exact tracklist" on a compilation
6. Settings showing Apple Music connected and on-device cover recognition

Use albums you own. Album artwork in screenshots is normal for music apps, but avoid implying endorsement by an artist or label.

## Release steps

1. App Store Connect › Apps › **+** › New App: platform iOS, name ShelfPlay, bundle ID `stream.shelfplay.app`, SKU `shelfplay-ios`.
2. developer.apple.com › Identifiers › `stream.shelfplay.app` › App Services: enable **MusicKit**.
3. Bump `CURRENT_PROJECT_VERSION` for each upload. Archive in Xcode (Product › Archive, scheme ShelfPlay, Any iOS Device) and **Distribute App › App Store Connect**.
4. **TestFlight** first: add yourself and family as internal testers.
5. Fill in the listing from this file, attach the build, and submit for review.
