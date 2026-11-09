const fs = require('fs');
const path = require('path');

// Escape text for embedding in a JS template literal: backslashes first, then backticks, then ${
function escapeTemplate(text) {
  return text.split('\\').join('\\\\').split('`').join('\\`').split('${').join('\\${');
}

// ─── Deployer values ──────────────────────────────────────────────────────────
// Never hardcoded in the repo. OPERATOR_NAME is read from index.html (deploy.sh injects it there);
// the others come from environment variables that deploy.sh can export.
const appHtml = fs.readFileSync('index.html', 'utf8');
const operatorMatch = appHtml.match(/const OPERATOR_NAME = '([^']*)'/);
const OPERATOR_NAME = process.env.SHELFPLAY_OPERATOR_NAME || (operatorMatch && operatorMatch[1]) || '';
const CONTACT_EMAIL = process.env.SHELFPLAY_CONTACT_EMAIL || '';
const APP_STORE_URL = process.env.SHELFPLAY_APP_STORE_URL || '';

function escapeHtml(s) {
  return s.replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;').replace(/"/g, '&quot;');
}

// Build-time tokens in site/*.html. %%ORIGIN%% is filled per request by the worker.
function fillTokens(html) {
  const operator = OPERATOR_NAME ? escapeHtml(OPERATOR_NAME) : 'the ShelfPlay team';
  const contact = CONTACT_EMAIL
    ? '<a href="mailto:' + escapeHtml(CONTACT_EMAIL) + '">' + escapeHtml(CONTACT_EMAIL) + '</a>'
    : '<a href="https://github.com/ncannings/Shelfplay/issues">GitHub Issues</a>';
  const appStore = APP_STORE_URL
    ? '<a class="store-badge" href="' + escapeHtml(APP_STORE_URL) + '"><span class="store-small">Download on the</span><span class="store-big">App Store</span></a>'
    : '<span class="store-badge store-soon" aria-disabled="true"><span class="store-small">Coming soon to the</span><span class="store-big">App Store</span></span>';
  return html
    .split('%%OPERATOR_NAME%%').join(operator)
    .split('%%CONTACT%%').join(contact)
    .split('%%APP_STORE_BADGE%%').join(appStore)
    .split('%%APP_STORE_URL%%').join(escapeHtml(APP_STORE_URL))
    .split('%%YEAR%%').join(String(new Date().getFullYear()));
}

// ─── Assets ───────────────────────────────────────────────────────────────────
const SITE = 'site';
const pages = {
  '/': 'landing.html',
  '/privacy': 'privacy.html',
  '/terms': 'terms.html',
  '/support': 'support.html',
};
const textAssets = {
  '/site.css': ['site.css', 'text/css;charset=UTF-8', 'public, max-age=3600'],
  '/robots.txt': ['robots.txt', 'text/plain;charset=UTF-8', 'public, max-age=86400'],
  '/sitemap.xml': ['sitemap.xml', 'application/xml;charset=UTF-8', 'public, max-age=86400'],
};
const binaryAssets = {
  '/og.jpg': ['og.jpg', 'image/jpeg', 'public, max-age=604800'],
  '/apple-touch-icon.png': ['apple-touch-icon.png', 'image/png', 'public, max-age=604800'],
};

const htmlHeaders = (cache) => "{ 'Content-Type': 'text/html;charset=UTF-8', 'Cache-Control': '" + cache + "', 'X-Content-Type-Options': 'nosniff' }";

let siteRoutes = '';
for (const [route, file] of Object.entries(pages)) {
  const html = escapeTemplate(fillTokens(fs.readFileSync(path.join(SITE, file), 'utf8')));
  siteRoutes +=
    "    if (path === '" + route + "'" + (route === '/' ? '' : " || path === '" + route + "/'") + ") {\n" +
    '      const html = `' + html + "`.split('%%ORIGIN%%').join(url.origin);\n" +
    '      return new Response(html, { headers: ' + htmlHeaders('public, max-age=300') + ' });\n' +
    '    }\n';
}
for (const [route, [file, type, cache]] of Object.entries(textAssets)) {
  const body = escapeTemplate(fs.readFileSync(path.join(SITE, file), 'utf8'));
  siteRoutes +=
    "    if (path === '" + route + "') {\n" +
    '      return new Response(`' + body + "`.split('%%ORIGIN%%').join(url.origin), { headers: { 'Content-Type': '" + type + "', 'Cache-Control': '" + cache + "' } });\n" +
    '    }\n';
}
for (const [route, [file, type, cache]] of Object.entries(binaryAssets)) {
  const b64 = fs.readFileSync(path.join(SITE, file)).toString('base64');
  siteRoutes +=
    "    if (path === '" + route + "') {\n" +
    "      const bytes = Uint8Array.from(atob('" + b64 + "'), (c) => c.charCodeAt(0));\n" +
    "      return new Response(bytes, { headers: { 'Content-Type': '" + type + "', 'Cache-Control': '" + cache + "' } });\n" +
    '    }\n';
}

// Read the worker routes template (no backticks in it)
const workerRoutes = fs.readFileSync('worker-routes.js', 'utf8');

// Build the final worker: web app + site pages + API routes
const worker = 'export default {\n' +
'  async fetch(request, env, ctx) {\n' +
'    const url = new URL(request.url);\n' +
'    const path = url.pathname;\n' +
'    const corsHeaders = {\n' +
"      'Access-Control-Allow-Origin': url.origin,\n" +
"      'Access-Control-Allow-Methods': 'GET, POST, OPTIONS',\n" +
"      'Access-Control-Allow-Headers': 'Content-Type, Authorization, X-Admin-Code',\n" +
'    };\n' +
'\n' +
"    if (request.method === 'OPTIONS') {\n" +
'      return new Response(null, { status: 204, headers: corsHeaders });\n' +
'    }\n' +
'\n' +
'    // The web app lives at /app (same origin as before, so saved libraries and the\n' +
'    // Spotify /callback redirect keep working).\n' +
"    if (path === '/app' || path === '/app/' || path === '/callback') {\n" +
'      const html = `' + escapeTemplate(appHtml) + '`;\n' +
'      return new Response(html, {\n' +
'        headers: {\n' +
"          'Content-Type': 'text/html;charset=UTF-8',\n" +
"          'Cache-Control': 'no-store, must-revalidate',\n" +
"          'X-Content-Type-Options': 'nosniff',\n" +
"          'Permissions-Policy': 'camera=(self), microphone=()',\n" +
'        },\n' +
'      });\n' +
'    }\n' +
'\n' +
siteRoutes + '\n' +
workerRoutes + '\n' +
"    return new Response('Not found', { status: 404 });\n" +
'  },\n' +
'};\n';

fs.writeFileSync('shelfplay-worker.js', worker, 'utf8');
console.log('Done - wrote ' + worker.length + ' bytes' + (OPERATOR_NAME ? '' : ' (no OPERATOR_NAME set — legal pages use a generic name)'));
