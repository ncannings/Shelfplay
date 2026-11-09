# ShelfPlay — Development Guide

## Architecture
One Cloudflare Worker serves everything, built into `shelfplay-worker.js` by `node build-worker.js`:
- `/` and `/privacy`, `/terms`, `/support` — public site pages from `site/` (landing page is Google-facing)
- `/app` (and `/callback` for Spotify OAuth) — the PWA, single file `index.html`. Same origin as before so saved libraries survive; installed PWAs opening `/` are redirected to `/app`
- `/api/*`, `/manifest.json`, `/icon.svg` — `worker-routes.js`

## iOS app (`ios/`)
Native SwiftUI app (iOS 18+; Apple Intelligence cover reading on iOS 26). Open `ios/ShelfPlay.xcodeproj`. The project uses synchronized folders, so new files under `ios/ShelfPlay/` are picked up automatically. Deployer values go in `ios/Support/Secrets.xcconfig` (gitignored; template in `Secrets.example.xcconfig`). Cover matching is fully on-device (`ios/ShelfPlay/Matching/`: Vision + Foundation Models). Playback: Apple Music (MusicKit) and Spotify (PKCE, no secret). See `ios/README.md`; App Store listing copy and steps in `ios/APP_STORE.md`. Spotify connect is hidden behind the ADMIN_CODE (5 taps on version) because Spotify dev mode allows only 5 accounts.

## Build & Deploy
```bash
bash deploy.sh          # Injects config, builds, deploys, restores clean source
```
Or manually:
```bash
node build-worker.js    # Combines index.html + worker-routes.js → shelfplay-worker.js
CLOUDFLARE_API_TOKEN=xxx npx wrangler deploy
```

## Key Files
- `index.html` — The entire SPA. Config constants at top of `<script>` block (~line 1142)
- `worker-routes.js` — All API routes. Gets inlined into the worker by build-worker.js
- `build-worker.js` — Build script. Escapes HTML for template literal embedding, inlines `site/` pages and assets
- `site/` — landing, privacy, terms, support pages + `site.css`, `robots.txt`, `sitemap.xml`, `og.jpg`. Tokens: `%%OPERATOR_NAME%%`, `%%CONTACT%%`, `%%APP_STORE_BADGE%%`, `%%YEAR%%` (build time), `%%ORIGIN%%` (per request)
- `wrangler.toml` — Cloudflare config (gitignored, use wrangler.toml.example as template)
- `deploy.sh` — Config injection + deploy (gitignored, contains real GA/operator values)

## Secrets (never in source)
All via `npx wrangler secret put NAME`:
- `SPOTIFY_CLIENT_ID` / `SPOTIFY_CLIENT_SECRET`
- `GEMINI_KEY`
- `ADMIN_CODE`

## Config (blank in repo, injected at deploy)
In `index.html` head: `GA_ID` variable
In `index.html` script: `GA_MEASUREMENT_ID`, `OPERATOR_NAME`, `PRIVACY_URL`, `TERMS_URL` (privacy/terms default to `/privacy`, `/terms`)
Site pages read `OPERATOR_NAME` from `index.html`; deploy.sh may also export `SHELFPLAY_CONTACT_EMAIL` and `SHELFPLAY_APP_STORE_URL` (App Store badge shows "Coming soon" until set)

## Security Rules
- NEVER commit credentials, API keys, account IDs, or personal info
- The repo must work with blank config defaults — all deployer-specific values go in deploy.sh or wrangler.toml (both gitignored)
- Spotify Client ID is served from /api/config (reads env.SPOTIFY_CLIENT_ID)
- wrangler.toml contains account_id and KV namespace ID — always gitignored
- Admin features hidden behind 5-tap gesture on version number in About section
