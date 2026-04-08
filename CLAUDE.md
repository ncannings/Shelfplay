# ShelfPlay — Development Guide

## Architecture
Single-file PWA: `index.html` (HTML+CSS+JS) + `worker-routes.js` (API routes) → built into `shelfplay-worker.js` via `node build-worker.js`. Runs on Cloudflare Workers.

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
- `build-worker.js` — Build script. Escapes HTML for template literal embedding
- `wrangler.toml` — Cloudflare config (gitignored, use wrangler.toml.example as template)
- `deploy.sh` — Config injection + deploy (gitignored, contains real GA/operator values)

## Secrets (never in source)
All via `npx wrangler secret put NAME`:
- `SPOTIFY_CLIENT_ID` / `SPOTIFY_CLIENT_SECRET`
- `GEMINI_KEY`
- `ADMIN_CODE`

## Config (blank in repo, injected at deploy)
In `index.html` head: `GA_ID` variable
In `index.html` script: `GA_MEASUREMENT_ID`, `OPERATOR_NAME`, `PRIVACY_URL`, `TERMS_URL`

## Security Rules
- NEVER commit credentials, API keys, account IDs, or personal info
- The repo must work with blank config defaults — all deployer-specific values go in deploy.sh or wrangler.toml (both gitignored)
- Spotify Client ID is served from /api/config (reads env.SPOTIFY_CLIENT_ID)
- wrangler.toml contains account_id and KV namespace ID — always gitignored
- Admin features hidden behind 5-tap gesture on version number in About section
