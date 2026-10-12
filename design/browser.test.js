import { chromium } from 'playwright';
import assert from 'node:assert/strict';
import { access, mkdtemp, readFile, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { createDesignServer } from './server.js';

const dir = await mkdtemp(join(tmpdir(), 'stretto-browser-test-'));
const server = createDesignServer({ feedbackPath: join(dir, 'feedback.json') });
await new Promise(resolve => server.listen(0, '127.0.0.1', resolve));
const url = `http://127.0.0.1:${server.address().port}`;
let browser;
try {
  const chrome = '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome';
  let launch = { headless: true };
  try { await access(chrome); launch.executablePath = chrome; } catch (error) { if (error.code !== 'ENOENT') throw error; }
  browser = await chromium.launch(launch);
  const page = await browser.newPage({ viewport: { width: 1440, height: 1100 } });
  const errors = [];
  page.on('pageerror', error => errors.push(error.message));
  await page.goto(url);
  await page.locator('[data-nav="9"]').waitFor();
  assert.equal(await page.locator('[data-nav]').count(), 10);
  for (const theme of ['dark', 'light']) {
    await page.locator(`[data-appearance="${theme}"]`).click();
    for (let i = 0; i < 10; i++) {
      await page.locator(`[data-nav="${i}"]`).click();
      assert.ok(await page.locator('#mock-title').innerText());
      assert.ok(await page.locator('#mock-container').innerText());
      const overflow = await page.evaluate(() => document.documentElement.scrollWidth > innerWidth);
      assert.equal(overflow, false, `Page overflow on screen ${i}, theme ${theme}`);
      const clipped = await page.locator('#mock-container').evaluate(el => el.scrollWidth > el.clientWidth + 1);
      assert.equal(clipped, false, `Mock overflow on screen ${i}, theme ${theme}`);
    }
  }
  await page.locator('[data-nav="0"]').click();
  await page.locator('[data-rating="5"]').click();
  await page.locator('#shortlist').check();
  await page.locator('#screen-notes').fill('Keep the calm sidebar and artwork.');
  await page.locator('[data-direction="editorial"]').click();
  await page.locator('#global-notes').fill('Native first. No browser wrapper.');
  await page.locator('#save').click();
  await page.getByText(/Saved to .local\/design-feedback.json/).waitFor();
  const saved = JSON.parse(await readFile(join(dir, 'feedback.json'), 'utf8'));
  assert.equal(saved.screens.library.rating, 5);
  assert.equal(saved.screens.library.shortlisted, true);
  assert.equal(saved.direction, 'editorial');
  await page.reload();
  assert.equal(await page.locator('#screen-notes').inputValue(), 'Keep the calm sidebar and artwork.');
  await page.locator('[data-nav="4"]').click();
  await page.locator('#demo-search').fill('Juniper');
  assert.equal(await page.locator('#search-results .track-row').count(), 1);
  await page.locator('#search-results [data-song="0"]').click();
  assert.equal(await page.locator('#demo-search').inputValue(), 'Juniper');
  await page.locator('[data-nav="8"]').click();
  await page.locator('[data-action="google"]').click();
  assert.match(await page.locator('#demo-status').innerText(), /system browser/);
  await page.locator('[data-login="recover"]').click();
  await page.locator('#demo-login button[type="submit"]').click();
  assert.match(await page.locator('#demo-status').innerText(), /No email was sent/);
  await page.locator('[data-nav="2"]').click();
  await page.locator('#mock-container [data-action="play"]').click();
  assert.match(await page.locator('#demo-status').innerText(), /simulation/);
  const download = page.waitForEvent('download');
  await page.locator('#export').click();
  assert.equal((await download).suggestedFilename(), 'stretto-native-design-brief.json');
  const fresh = await browser.newPage();
  await fresh.goto(url);
  await fresh.getByText('Restored your saved project brief.', { exact: false }).waitFor();
  assert.equal(await fresh.locator('#screen-notes').inputValue(), 'Keep the calm sidebar and artwork.');
  await fresh.close();
  await page.setViewportSize({ width: 390, height: 844 });
  for (let i = 0; i < 10; i++) {
    await page.locator(`[data-nav="${i}"]`).click();
    assert.equal(await page.evaluate(() => document.documentElement.scrollWidth > innerWidth), false, `Mobile page overflow ${i}`);
    assert.equal(await page.locator('#mock-container').evaluate(el => el.scrollWidth > el.clientWidth + 1), false, `Mobile mock overflow ${i}`);
  }
  assert.deepEqual(errors, []);
  console.log('Browser checks passed: 10 mocks, both themes, mobile layout, interactions, feedback persistence, restore and export.');
} finally {
  if (browser) await browser.close();
  await new Promise(resolve => server.close(resolve));
  await rm(dir, { recursive: true });
}
