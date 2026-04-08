const fs = require('fs');
let html = fs.readFileSync('index.html', 'utf8');

// Escape for JS template literal: backslashes first, then backticks, then ${
html = html.split('\\').join('\\\\');
html = html.split('`').join('\\`');
html = html.split('${').join('\\${');

// Read the worker routes template (no backticks in it)
const workerRoutes = fs.readFileSync('worker-routes.js', 'utf8');

// Build the final worker: HTML as template literal + routes
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
"    if (path === '/' || path === '/callback') {\n" +
'      const html = `' + html + '`;\n' +
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
workerRoutes + '\n' +
"    return new Response('Not found', { status: 404 });\n" +
'  },\n' +
'};\n';

fs.writeFileSync('shelfplay-worker.js', worker, 'utf8');
console.log('Done - wrote ' + worker.length + ' bytes');
