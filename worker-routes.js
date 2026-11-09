    // ─── Spotify client config (public, needed for browser OAuth) ────
    if (path === '/api/config' && request.method === 'GET') {
      return new Response(JSON.stringify({ spotify_client_id: env.SPOTIFY_CLIENT_ID || '' }), {
        headers: { 'Content-Type': 'application/json', 'Cache-Control': 'public, max-age=3600', ...corsHeaders },
      });
    }

    // ─── Spotify token exchange ───────────────────────────────────────
    if (path === '/api/token' && request.method === 'POST') {
      try {
        const { code, redirect_uri, code_verifier } = await request.json();
        const body = new URLSearchParams({
          client_id: env.SPOTIFY_CLIENT_ID,
          client_secret: env.SPOTIFY_CLIENT_SECRET,
          grant_type: 'authorization_code',
          code, redirect_uri, code_verifier,
        });
        const r = await fetch('https://accounts.spotify.com/api/token', {
          method: 'POST',
          headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
          body,
        });
        const data = await r.json();
        return new Response(JSON.stringify(data), {
          status: r.status,
          headers: { 'Content-Type': 'application/json', 'Cache-Control': 'no-store', ...corsHeaders },
        });
      } catch (e) {
        return new Response(JSON.stringify({ error: e.message }), {
          status: 500, headers: { 'Content-Type': 'application/json', ...corsHeaders },
        });
      }
    }

    // ─── Spotify token refresh ────────────────────────────────────────
    if (path === '/api/refresh' && request.method === 'POST') {
      try {
        const { refresh_token } = await request.json();
        const body = new URLSearchParams({
          client_id: env.SPOTIFY_CLIENT_ID,
          client_secret: env.SPOTIFY_CLIENT_SECRET,
          grant_type: 'refresh_token',
          refresh_token,
        });
        const r = await fetch('https://accounts.spotify.com/api/token', {
          method: 'POST',
          headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
          body,
        });
        const data = await r.json();
        return new Response(JSON.stringify(data), {
          status: r.status,
          headers: { 'Content-Type': 'application/json', 'Cache-Control': 'no-store', ...corsHeaders },
        });
      } catch (e) {
        return new Response(JSON.stringify({ error: e.message }), {
          status: 500, headers: { 'Content-Type': 'application/json', ...corsHeaders },
        });
      }
    }

    // ─── Vision endpoint (admin-only, Gemini) ────────────────────────
    if (path === '/api/vision' && request.method === 'POST') {
      try {
        const body = await request.json();
        const { image_base64 } = body;
        const adminCode = request.headers.get('X-Admin-Code') || '';
        const isAdmin = adminCode && adminCode === env.ADMIN_CODE;
        const prompt = 'This is a vinyl record or CD album cover. Return ONLY a JSON object like {"title":"...","artist":"..."}. No markdown, no code fences, no explanation.';

        if (!isAdmin) {
          return new Response(JSON.stringify({ error: 'Add your Gemini API key in Settings to identify covers.' }), {
            status: 403, headers: { 'Content-Type': 'application/json', ...corsHeaders },
          });
        }

        if (!env.GEMINI_KEY) {
          return new Response(JSON.stringify({ error: 'Gemini key not configured' }), {
            status: 503, headers: { 'Content-Type': 'application/json', ...corsHeaders },
          });
        }

        const models = ['gemini-3-flash-preview', 'gemini-2.5-flash'];
        const geminiBody = JSON.stringify({
          contents: [{
            parts: [
              { inline_data: { mime_type: 'image/jpeg', data: image_base64 } },
              { text: prompt }
            ]
          }],
          generationConfig: {
            maxOutputTokens: 256,
            responseMimeType: 'application/json',
            responseSchema: {
              type: 'OBJECT',
              properties: {
                title: { type: 'STRING' },
                artist: { type: 'STRING' }
              },
              required: ['title', 'artist']
            },
            thinkingConfig: { thinkingBudget: 0 }
          }
        });
        for (const model of models) {
          try {
            const geminiR = await fetch(
              'https://generativelanguage.googleapis.com/v1beta/models/' + model + ':generateContent?key=' + env.GEMINI_KEY,
              { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: geminiBody, signal: AbortSignal.timeout(30000) }
            );
            if (geminiR.status === 503 || geminiR.status === 429) continue;
            const geminiData = await geminiR.json();
            const text = geminiData.candidates?.[0]?.content?.parts?.[0]?.text;
            if (text) {
              return new Response(JSON.stringify({ source: 'gemini', content: text }), {
                headers: { 'Content-Type': 'application/json', ...corsHeaders },
              });
            }
          } catch (e) { if (model === models[models.length - 1]) throw e; }
        }

        return new Response(JSON.stringify({ error: 'All Gemini models unavailable — try again shortly' }), {
          status: 503, headers: { 'Content-Type': 'application/json', ...corsHeaders },
        });
      } catch (e) {
        return new Response(JSON.stringify({ error: e.message }), {
          status: 500, headers: { 'Content-Type': 'application/json', ...corsHeaders },
        });
      }
    }

    // ─── Library save (family code) ─────────────────────────────────
    // Merges incoming library with existing cloud library (union by URI)
    if (path === '/api/library/save' && request.method === 'POST') {
      try {
        const { family_code, library_data } = await request.json();
        if (!family_code || typeof family_code !== 'string' || family_code.length < 3) {
          return new Response(JSON.stringify({ error: 'Invalid family code' }), {
            status: 400, headers: { 'Content-Type': 'application/json', ...corsHeaders },
          });
        }
        const kvKey = 'family:' + family_code;

        // Merge with existing cloud library (other family members' contributions)
        const existing = await env.SHELFPLAY_KV.get(kvKey);
        let cloudLib = [];
        try { cloudLib = JSON.parse(existing || '[]'); } catch(e) {}

        const cloudUris = new Set(cloudLib.map(a => a.uri));
        const incoming = Array.isArray(library_data) ? library_data : [];
        let added = 0;
        for (const album of incoming) {
          if (album.uri && !cloudUris.has(album.uri)) {
            cloudLib.push(album);
            cloudUris.add(album.uri);
            added++;
          }
        }

        // Sort by scannedAt desc, cap at 1000
        cloudLib.sort((a, b) => new Date(b.scannedAt || 0) - new Date(a.scannedAt || 0));
        if (cloudLib.length > 1000) cloudLib = cloudLib.slice(0, 1000);

        await env.SHELFPLAY_KV.put(kvKey, JSON.stringify(cloudLib));
        return new Response(JSON.stringify({ ok: true, total: cloudLib.length, added }), {
          headers: { 'Content-Type': 'application/json', ...corsHeaders },
        });
      } catch (e) {
        return new Response(JSON.stringify({ error: e.message }), {
          status: 500, headers: { 'Content-Type': 'application/json', ...corsHeaders },
        });
      }
    }

    // ─── Library load (family code) ──────────────────────────────────
    if (path === '/api/library/load' && request.method === 'GET') {
      try {
        const familyCode = url.searchParams.get('family_code');
        if (!familyCode || familyCode.length < 3) {
          return new Response(JSON.stringify({ error: 'Invalid family code' }), {
            status: 400, headers: { 'Content-Type': 'application/json', ...corsHeaders },
          });
        }
        const data = await env.SHELFPLAY_KV.get('family:' + familyCode);
        return new Response(data || '[]', {
          headers: { 'Content-Type': 'application/json', ...corsHeaders },
        });
      } catch (e) {
        return new Response(JSON.stringify({ error: e.message }), {
          status: 500, headers: { 'Content-Type': 'application/json', ...corsHeaders },
        });
      }
    }

    // ─── PWA manifest ─────────────────────────────────────────────
    if (path === '/manifest.json') {
      const manifest = JSON.stringify({
        name: 'ShelfPlay',
        short_name: 'ShelfPlay',
        description: 'Scan vinyl records and CDs, build your shelf, and play on Spotify',
        start_url: '/app',
        scope: '/',
        display: 'standalone',
        background_color: '#0c0a09',
        theme_color: '#0c0a09',
        icons: [
          { src: '/icon.svg', sizes: 'any', type: 'image/svg+xml', purpose: 'any maskable' },
        ],
      });
      return new Response(manifest, {
        headers: {
          'Content-Type': 'application/manifest+json',
          'Cache-Control': 'public, max-age=86400',
          ...corsHeaders,
        },
      });
    }

    // ─── App icon (SVG) ─────────────────────────────────────────────
    if (path === '/icon.svg') {
      const svg = '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 1024 1024"><defs><linearGradient id="bg" x1="0" y1="0" x2="1" y2="1"><stop offset="0" stop-color="#2a221c"/><stop offset="1" stop-color="#0c0a09"/></linearGradient><radialGradient id="glow" cx="50%" cy="46%" r="55%"><stop offset="0" stop-color="#f59e0b" stop-opacity=".18"/><stop offset="1" stop-color="#f59e0b" stop-opacity="0"/></radialGradient><linearGradient id="amber" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stop-color="#fbbf24"/><stop offset="1" stop-color="#d97706"/></linearGradient><linearGradient id="sleeve" x1="0" y1="0" x2="1" y2="1"><stop offset="0" stop-color="#ea580c"/><stop offset="1" stop-color="#9a3412"/></linearGradient><radialGradient id="vinyl" cx="50%" cy="50%" r="50%"><stop offset="0" stop-color="#2e2926"/><stop offset="1" stop-color="#141110"/></radialGradient><clipPath id="frameClip"><rect x="232" y="232" width="560" height="560" rx="40"/></clipPath></defs><rect fill="url(#bg)"/><rect fill="url(#glow)"/><g transform="rotate(-6 512 512)"><g transform="translate(652 520)"><circle r="200" fill="url(#vinyl)"/><circle r="200" fill="none" stroke="#5a504a" stroke-width="6"/><circle r="168" fill="none" stroke="#4a423d" stroke-width="5"/><circle r="138" fill="none" stroke="#4a423d" stroke-width="5"/><circle r="108" fill="none" stroke="#4a423d" stroke-width="5"/><circle r="72" fill="url(#amber)"/><circle r="12" fill="#0c0a09"/></g><rect x="236" y="300" width="420" height="420" rx="20" fill="url(#sleeve)"/><rect x="236" y="300" width="420" height="420" rx="20" fill="none" stroke="#fdba74" stroke-opacity=".3" stroke-width="4"/><rect x="282" y="350" width="206" height="36" rx="11" fill="#fff7ed" fill-opacity=".92"/><rect x="282" y="406" width="132" height="24" rx="9" fill="#fff7ed" fill-opacity=".55"/></g><g fill="none" stroke="url(#amber)" stroke-width="44" stroke-linecap="round" stroke-linejoin="round"><path d="M168 330 V218 Q168 168 218 168 H330"/><path d="M694 168 H806 Q856 168 856 218 V330"/><path d="M856 694 V806 Q856 856 806 856 H694"/><path d="M330 856 H218 Q168 856 168 806 V694"/></g></svg>';
      return new Response(svg, {
        headers: {
          'Content-Type': 'image/svg+xml',
          'Cache-Control': 'public, max-age=604800',
          ...corsHeaders,
        },
      });
    }


