# ShelfPlay

Scan vinyl records and CDs by barcode or album cover, then play them on Spotify. A progressive web app powered by Cloudflare Workers.

## See It In Action

### Self-hosted (full Spotify control)
Scan a barcode, identify the album, and play directly on Alexa — all in seconds.

<video src="https://github.com/ncannings/Shelfplay/raw/main/videos/self_hosted_version.MP4" controls width="300"></video>

### Web version (no setup required)
Scan and identify albums, then open them in Spotify.

<video src="https://github.com/ncannings/Shelfplay/raw/main/videos/web_version.MP4" controls width="300"></video>

## Try It

**[shelfplay.stream](https://shelfplay.stream)** — open on your phone, install as a PWA, and start scanning.

The hosted version is free to use with these limitations:

| Feature | Hosted (shelfplay.stream) | Self-hosted |
|---------|--------------------------|-------------|
| Barcode scanning | Unlimited | Unlimited |
| Cover art recognition | Requires your own Gemini API key | Requires your own Gemini API key |
| Spotify playback | Open in Spotify (deep link) | Direct device control (Play on Alexa, etc.) |
| Spotify playlist building | Requires your own Spotify app | Full control |
| Family sharing | Available | Available |
| Cloud library sync | Shared infrastructure | Your own KV store |

To get the full experience — direct playback to your speakers, playlist creation, Spotify library integration — deploy your own instance. It takes about 10 minutes and costs nothing.

## Features

- **Barcode scanning** — point your camera at a UPC/EAN barcode to identify albums via MusicBrainz and Discogs
- **Cover art recognition** — capture an album cover and identify it with Google Gemini AI (BYOK)
- **Spotify playback** — play identified albums directly on your Spotify-connected devices
- **Smart compilation handling** — detects when Spotify matches the wrong edition and lets you build a track-by-track playlist from the correct release
- **Family sharing** — share your scanned library with family members via a simple code
- **Works offline-first** — library stored locally, syncs when online
- **Installable PWA** — add to your home screen for a native app experience

## Deploy Your Own

ShelfPlay runs entirely on Cloudflare Workers (free tier is sufficient). Here's how to deploy your own instance.

### Prerequisites

- A [Cloudflare account](https://dash.cloudflare.com/sign-up) (free)
- A domain added to Cloudflare (or use the free `*.workers.dev` subdomain)
- [Node.js](https://nodejs.org/) installed locally
- A [Spotify Developer](https://developer.spotify.com/dashboard) app (free)
- A [Google Gemini API key](https://aistudio.google.com/apikey) (free tier available — needed for cover recognition)

### Step 1: Clone and configure

```bash
git clone https://github.com/ncannings/Shelfplay.git
cd Shelfplay
```

Edit the configuration constants at the top of `index.html`:

```javascript
const GA_MEASUREMENT_ID = '';  // Your GA4 ID, or '' to disable analytics
const OPERATOR_NAME = 'Your Name or Company';
const PRIVACY_URL = 'https://your-site.com/privacy';
const TERMS_URL = 'https://your-site.com/terms';
```

Also update the `GA_ID` variable in the `<head>` section (or remove the GA script block entirely if you don't want analytics).

The Spotify Client ID is loaded from the server at startup (set via `wrangler secret put SPOTIFY_CLIENT_ID`) — it is not hardcoded in the source.

### Step 2: Create a Spotify app

1. Go to [Spotify Developer Dashboard](https://developer.spotify.com/dashboard)
2. Create a new app
3. Set the redirect URI to `https://your-domain.com/callback`
4. Note the **Client ID** and **Client Secret** — both are set as Worker secrets in Step 4

**Required Spotify scopes** (configured automatically):
`user-read-playback-state user-modify-playback-state user-library-modify user-library-read playlist-modify-private playlist-modify-public`

### Step 3: Set up Cloudflare

```bash
# Copy the example config
cp wrangler.toml.example wrangler.toml
```

Edit `wrangler.toml` with your Cloudflare account ID and domain:

```toml
account_id = "your-cloudflare-account-id"

routes = [
  { pattern = "your-domain.com", custom_domain = true }
]
```

Create a KV namespace:

```bash
npx wrangler kv namespace create SHELFPLAY_KV
```

Copy the returned namespace ID into `wrangler.toml`.

### Step 4: Set secrets

```bash
# Spotify credentials
echo "your-spotify-client-id" | npx wrangler secret put SPOTIFY_CLIENT_ID
echo "your-spotify-client-secret" | npx wrangler secret put SPOTIFY_CLIENT_SECRET

# Gemini API key (for admin server-side vision)
echo "your-gemini-key" | npx wrangler secret put GEMINI_KEY

# Admin code (unlocks server-side features — choose something strong)
echo "your-admin-code" | npx wrangler secret put ADMIN_CODE
```

### Step 5: Build and deploy

```bash
node build-worker.js
npx wrangler deploy
```

That's it! Your instance is live.

### Step 6 (optional): Custom domain

If you used `custom_domain = true` in your routes, Cloudflare automatically creates DNS records and provisions SSL. If using `*.workers.dev`, it works immediately.

## Architecture

```
index.html          — The entire SPA (HTML + CSS + JS, single file)
worker-routes.js    — Cloudflare Worker API routes
build-worker.js     — Build script: inlines index.html into the worker
wrangler.toml       — Cloudflare deployment config (not committed)
icon.svg            — App icon (vinyl record)
```

The build script (`node build-worker.js`) combines `index.html` and `worker-routes.js` into a single `shelfplay-worker.js` that Cloudflare Workers executes. The HTML is served inline — no static file hosting needed.

### API endpoints

| Endpoint | Method | Auth | Description |
|----------|--------|------|-------------|
| `/` | GET | - | Serves the SPA |
| `/callback` | GET | - | Spotify OAuth callback |
| `/api/config` | GET | - | Public config (Spotify Client ID) |
| `/api/token` | POST | - | Spotify token exchange |
| `/api/refresh` | POST | - | Spotify token refresh |
| `/api/vision` | POST | Admin | Gemini vision (admin only) |
| `/api/library/save` | POST | Family code | Save library to cloud |
| `/api/library/load` | GET | Family code | Load library from cloud |
| `/manifest.json` | GET | - | PWA manifest |
| `/icon.svg` | GET | - | App icon |

### Security model

- **Spotify Client ID** — stored as a Worker secret, served to the browser via `/api/config` (public by design in OAuth, but not hardcoded in source).
- **Spotify Client Secret** — stored as a Cloudflare Worker secret, never exposed to the browser. Token exchange happens server-side.
- **Gemini API key (server)** — stored as a Worker secret, only accessible with the admin code.
- **Gemini API key (users)** — BYOK, stored in the browser's localStorage, never sent to the server. API calls go directly from the browser to Google.
- **Admin code** — validated server-side against `env.ADMIN_CODE`. Hidden behind a tap gesture (tap version number 5 times in About section).
- **Family codes** — used as KV keys for cloud library sync. Generated with crypto-random characters.
- **CORS** — mirrors request origin (standard for SPAs served from the same worker).
- **No cookies** — except optional Google Analytics (with consent banner and Google Consent Mode v2).

## How users get a Gemini API key

Cover recognition requires a Google Gemini API key. The free tier is generous for personal use.

1. Go to [Google AI Studio](https://aistudio.google.com/apikey)
2. Click "Create API key"
3. Copy the key into ShelfPlay Settings > Cover Vision > Gemini API Key

The key stays on the user's device and is never sent to your server. API calls go directly from the browser to Google's API.

## License

MIT
