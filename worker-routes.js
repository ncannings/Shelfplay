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
        start_url: '/',
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
      const svg = '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 512 512">' +
        '<defs>' +
        '<linearGradient id="bg" x1="0" y1="0" x2="1" y2="1">' +
        '<stop offset="0%" stop-color="#1c1917"/>' +
        '<stop offset="100%" stop-color="#0c0a09"/>' +
        '</linearGradient>' +
        '<linearGradient id="amber" x1="0" y1="0" x2="0" y2="1">' +
        '<stop offset="0%" stop-color="#f59e0b"/>' +
        '<stop offset="100%" stop-color="#d97706"/>' +
        '</linearGradient>' +
        '</defs>' +
        '<rect width="512" height="512" rx="112" fill="url(#bg)"/>' +
        '<circle cx="256" cy="256" r="190" fill="none" stroke="#292524" stroke-width="2"/>' +
        '<circle cx="256" cy="256" r="170" fill="none" stroke="#292524" stroke-width="1"/>' +
        '<circle cx="256" cy="256" r="150" fill="none" stroke="#292524" stroke-width="1"/>' +
        '<circle cx="256" cy="256" r="130" fill="none" stroke="#3a3532" stroke-width="1"/>' +
        '<circle cx="256" cy="256" r="110" fill="none" stroke="#292524" stroke-width="1"/>' +
        '<circle cx="256" cy="256" r="90" fill="none" stroke="#292524" stroke-width="1.5"/>' +
        '<circle cx="256" cy="256" r="85" fill="#1c1917"/>' +
        '<circle cx="256" cy="256" r="82" fill="none" stroke="url(#amber)" stroke-width="2" opacity="0.3"/>' +
        '<text x="256" y="295" text-anchor="middle" font-family="Georgia,serif" font-size="160" font-weight="bold" font-style="italic" fill="url(#amber)">SP</text>' +
        '<circle cx="256" cy="256" r="200" fill="none" stroke="#d97706" stroke-width="3" opacity="0.2"/>' +
        '<circle cx="256" cy="256" r="203" fill="none" stroke="#d97706" stroke-width="1" opacity="0.1"/>' +
        '<circle cx="256" cy="256" r="12" fill="#0c0a09"/>' +
        '<circle cx="256" cy="256" r="10" fill="none" stroke="#292524" stroke-width="1"/>' +
        '</svg>';
      return new Response(svg, {
        headers: {
          'Content-Type': 'image/svg+xml',
          'Cache-Control': 'public, max-age=604800',
          ...corsHeaders,
        },
      });
    }


