import { test } from 'node:test';
import assert from 'node:assert/strict';
import { mkdtemp, readFile, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { createDesignServer } from './server.js';

const brief = () => ({
  schemaVersion: 1, appearance: 'dark', direction: 'glass', density: 'comfortable',
  notes: 'Prefer understated native controls.', priorities: ['media', 'offline'],
  screens: Object.fromEntries(['library', 'playlist', 'player', 'mini', 'search', 'artists', 'offline', 'sync', 'login', 'settings']
    .map(id => [id, { rating: 4, shortlisted: id === 'library', notes: 'Keep this.' }])),
});

test('serves ten-mock studio and persists validated local feedback', async t => {
  const dir = await mkdtemp(join(tmpdir(), 'stretto-studio-test-'));
  const feedbackPath = join(dir, 'feedback.json');
  const server = createDesignServer({ feedbackPath });
  await new Promise(resolve => server.listen(0, '127.0.0.1', resolve));
  t.after(async () => { await new Promise(resolve => server.close(resolve)); await rm(dir, { recursive: true }); });
  const base = `http://127.0.0.1:${server.address().port}`;
  const html = await fetch(base);
  assert.equal(html.status, 200);
  assert.match(await html.text(), /Ten moments/);
  assert.match(html.headers.get('content-security-policy'), /frame-ancestors 'none'/);
  assert.equal((await fetch(`${base}/studio.js`)).status, 200);
  assert.equal((await fetch(`${base}/studio.css`)).status, 200);
  assert.equal((await fetch(`${base}/../package.json`)).status, 404);
  assert.equal(await (await fetch(`${base}/api/feedback`)).json(), null);
  const { token } = await (await fetch(`${base}/api/session`)).json();
  const headers = { 'Content-Type': 'application/json', 'X-Studio-Token': token };
  const post = (value, extraHeaders = headers) => fetch(`${base}/api/feedback`, { method: 'POST', headers: extraHeaders, body: JSON.stringify(value) });
  assert.equal((await post(brief(), { 'Content-Type': 'application/json' })).status, 403);
  assert.equal((await post(brief(), { ...headers, Origin: 'https://example.com' })).status, 403);
  const invalid = brief(); invalid.screens.library.rating = 6;
  assert.equal((await post(invalid)).status, 400);
  const incomplete = brief(); delete incomplete.screens.login;
  assert.equal((await post(incomplete)).status, 400);
  const oversized = brief(); oversized.notes = 'x'.repeat(110000);
  assert.equal((await post(oversized)).status, 413);
  const response = await post(brief());
  assert.equal(response.status, 200);
  const disk = JSON.parse(await readFile(feedbackPath, 'utf8'));
  assert.equal(disk.screens.library.rating, 4);
  assert.equal(disk.screens.library.shortlisted, true);
  assert.equal(disk.direction, 'glass');
  assert.ok(disk.savedAt);
  assert.deepEqual(await (await fetch(`${base}/api/feedback`)).json(), disk);
  const updated = brief(); updated.direction = 'compact';
  assert.equal((await post(updated)).status, 200);
  assert.equal(JSON.parse(await readFile(feedbackPath, 'utf8')).direction, 'compact');
});
