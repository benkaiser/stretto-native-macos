import http from 'node:http';
import { readFile, mkdir, writeFile, rename } from 'node:fs/promises';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { randomBytes, timingSafeEqual } from 'node:crypto';

const root = dirname(fileURLToPath(import.meta.url));
const assets = new Map([
  ['/', ['index.html', 'text/html; charset=utf-8']],
  ['/studio.css', ['studio.css', 'text/css; charset=utf-8']],
  ['/studio.js', ['studio.js', 'text/javascript; charset=utf-8']],
]);
const ids = ['library', 'playlist', 'player', 'mini', 'search', 'artists', 'offline', 'sync', 'login', 'settings'];
const priorities = ['media', 'offline', 'remote', 'discovery', 'import', 'lyrics'];

export function validateBrief(value) {
  if (!value || value.schemaVersion !== 1 || !['light', 'dark', 'system'].includes(value.appearance)
    || !['glass', 'editorial', 'compact'].includes(value.direction)
    || !['comfortable', 'dense'].includes(value.density)
    || typeof value.notes !== 'string' || value.notes.length > 12000
    || !Array.isArray(value.priorities) || value.priorities.some(p => !priorities.includes(p))
    || !value.screens || typeof value.screens !== 'object'
    || Object.keys(value.screens).length !== ids.length) return false;
  return ids.every(id => {
    const screen = value.screens[id];
    return screen && Number.isInteger(screen.rating) && screen.rating >= 0 && screen.rating <= 5
      && typeof screen.shortlisted === 'boolean' && typeof screen.notes === 'string'
      && screen.notes.length <= 6000;
  });
}

export function createDesignServer({ feedbackPath = join(root, '../.local/design-feedback.json') } = {}) {
  const token = randomBytes(32).toString('hex');
  let writing = Promise.resolve();
  return http.createServer(async (req, res) => {
    const send = (status, data, type = 'application/json; charset=utf-8') => {
      res.writeHead(status, {
        'Content-Type': type, 'Cache-Control': 'no-store',
        'X-Content-Type-Options': 'nosniff',
        'Content-Security-Policy': "default-src 'self'; script-src 'self'; style-src 'self' 'unsafe-inline'; img-src 'self' data:; connect-src 'self'; object-src 'none'; frame-ancestors 'none'; base-uri 'none'",
      });
      res.end(type.startsWith('application/json') ? JSON.stringify(data) : data);
    };
    const expectedOrigin = `http://${req.headers.host}`;
    if (!/^127\.0\.0\.1:\d+$/.test(req.headers.host || '')) return send(403, { error: 'Loopback host required.' });
    if (req.headers.origin && req.headers.origin !== expectedOrigin) return send(403, { error: 'Cross-origin access denied.' });
    try {
      if (req.method === 'GET' && req.url === '/api/session') return send(200, { token });
      if (req.method === 'GET' && req.url === '/api/feedback') {
        try {
          return send(200, JSON.parse(await readFile(feedbackPath, 'utf8')));
        } catch (error) {
          if (error.code === 'ENOENT') return send(200, null);
          throw error;
        }
      }
      if (req.method === 'POST' && req.url === '/api/feedback') {
        const supplied = Buffer.from(req.headers['x-studio-token'] || '');
        if (supplied.length !== token.length || !timingSafeEqual(supplied, Buffer.from(token))) {
          return send(403, { error: 'Invalid studio session. Reload this page.' });
        }
        if (req.headers['content-type'] !== 'application/json') return send(415, { error: 'JSON required.' });
        let body = '';
        for await (const chunk of req) {
          body += chunk;
          if (Buffer.byteLength(body) > 100000) return send(413, { error: 'Design brief exceeds 100 KB.' });
        }
        let value;
        try { value = JSON.parse(body); } catch { return send(400, { error: 'Invalid JSON.' }); }
        if (!validateBrief(value)) return send(400, { error: 'Invalid design brief fields.' });
        const brief = {
          schemaVersion: 1, appearance: value.appearance, direction: value.direction, density: value.density,
          priorities: [...new Set(value.priorities)], notes: value.notes,
          screens: Object.fromEntries(ids.map(id => [id, {
            rating: value.screens[id].rating, shortlisted: value.screens[id].shortlisted, notes: value.screens[id].notes,
          }])),
          savedAt: new Date().toISOString(),
        };
        const write = writing.then(async () => {
          await mkdir(dirname(feedbackPath), { recursive: true });
          await writeFile(`${feedbackPath}.tmp`, `${JSON.stringify(brief, null, 2)}\n`, { mode: 0o600 });
          await rename(`${feedbackPath}.tmp`, feedbackPath);
        });
        writing = write.catch(error => console.error('Design brief write failed:', error.message));
        await write;
        return send(200, { savedAt: brief.savedAt, path: '.local/design-feedback.json' });
      }
      if (req.method === 'GET' && assets.has(req.url)) {
        const [name, type] = assets.get(req.url);
        return send(200, await readFile(join(root, name)), type);
      }
      return send(404, { error: 'Not found.' });
    } catch (error) {
      console.error('Design studio request failed:', error.message);
      if (!res.headersSent) send(500, { error: 'Could not read or save studio data. Check the server log.' });
    }
  });
}

if (process.argv[1] === fileURLToPath(import.meta.url)) {
  const port = Number(process.env.PORT || 4317);
  if (!Number.isInteger(port) || port < 1 || port > 65535) throw new Error('PORT must be between 1 and 65535.');
  const server = createDesignServer();
  server.on('error', error => {
    console.error(`Design studio failed to start: ${error.message}`);
    process.exitCode = 1;
  });
  server.listen(port, '127.0.0.1', () => console.log(`Stretto design studio: http://127.0.0.1:${port}`));
}
