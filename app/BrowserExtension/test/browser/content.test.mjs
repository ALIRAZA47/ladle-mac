// The content script in Chromium, with a stand-in for the extension APIs.
import { test, before, after } from 'node:test';
import assert from 'node:assert/strict';
import { createRequire } from 'node:module';
import { readFileSync, mkdirSync } from 'node:fs';
import { startServer } from './server.mjs';

const require = createRequire(import.meta.url);
const { chromium } = require('playwright');
const H = require('../../src/lib/hls.js');

const src = (path) => readFileSync(new URL(`../../src/${path}`, import.meta.url), 'utf8');
const fixture = (name) => readFileSync(new URL(`../fixtures/${name}`, import.meta.url), 'utf8');
const shots = process.env.LADLE_SCREENSHOTS;

let site;
let browser;

before(async () => {
  site = await startServer();
  browser = await chromium.launch();
});

after(async () => {
  await browser.close();
  await site.close();
});

/** Opens `path` with a fake `browser` API that records messages and answers from `answers`. */
async function open(path, answers) {
  const page = await browser.newPage({ viewport: { width: 900, height: 620 } });
  await page.addInitScript((answersArg) => {
    window.__sent = [];
    window.__listeners = [];
    window.browser = {
      runtime: {
        sendMessage(message) {
          window.__sent.push(message);
          const answer = answersArg[message.type];
          return Promise.resolve(answer === undefined ? null : answer);
        },
        onMessage: { addListener: (fn) => window.__listeners.push(fn) },
      },
    };
  }, answers);
  await page.goto(site.origin + path);
  await page.addScriptTag({ content: src('lib/ladle-common.js') });
  await page.addScriptTag({ content: src('content.js') });
  return page;
}

const shadow = (page, selector) =>
  page.evaluate((sel) => {
    const host = document.querySelector('ladle-video-button');
    const el = host && host.shadowRoot.querySelector(sel);
    return el ? el.textContent.replace(/\s+/g, ' ').trim() : null;
  }, selector);

const clickShadow = (page, selector) =>
  page.evaluate((sel) => document.querySelector('ladle-video-button').shadowRoot.querySelector(sel).click(), selector);

const sent = (page, type) => page.evaluate((t) => window.__sent.filter((m) => m.type === t), type);

async function hoverVideo(page) {
  await page.mouse.move(100, 100);
  await page.mouse.move(400, 300, { steps: 4 });
}

test('a direct video gets the pill and its menu', async () => {
  const page = await open('/video.html', {
    getConfig: { interceptClicks: false, catchTypes: ['mp4'], videoFolder: 'Downloads › Ladle › Video' },
    inspectVideo: { options: [{ label: 'Original', format: 'MP4', size: null, url: 'http://x/clip.mp4', kind: 'file' }] },
    saveVideo: { ok: true },
  });
  await hoverVideo(page);
  await page.waitForFunction(() => document.querySelector('ladle-video-button')?.shadowRoot.querySelector('.pill.shown'));
  assert.equal(await shadow(page, '.pill'), 'Download video');
  const inspected = await sent(page, 'inspectVideo');
  assert.match(inspected[0].src, /\/media\/clip\.mp4$/);
  await clickShadow(page, '.pill');
  assert.equal(await shadow(page, '.menu .title'), 'Save this video');
  assert.match(await shadow(page, '.menu .sub'), /^Designing for Speed/);
  assert.equal(await shadow(page, '.folder'), 'Downloads › Ladle › Video');
  assert.equal(await shadow(page, '.go'), 'Download video');
  await clickShadow(page, '.go');
  await page.waitForFunction(() => window.__sent.some((m) => m.type === 'saveVideo'));
  const [save] = await sent(page, 'saveVideo');
  assert.equal(save.option.url, 'http://x/clip.mp4');
  assert.equal(save.title, 'Designing for Speed');
  await page.waitForFunction(() => document.querySelector('ladle-video-button').shadowRoot.querySelector('.pill')?.textContent.includes('Sent to Ladle'));
  await page.close();
});

test('an HLS stream offers its qualities, 1080p first choice', async () => {
  const master = H.parse(fixture('master.m3u8'), 'https://v.example.org/master.m3u8');
  const media = H.parse(fixture('fmp4.m3u8'), 'https://v.example.org/1080p/index.m3u8');
  const options = H.menuOptions(master, media);
  const page = await open('/video.html', {
    getConfig: { interceptClicks: false, catchTypes: [], videoFolder: 'Downloads › Ladle › Video' },
    inspectVideo: { options, duration: 2538 },
  });
  await hoverVideo(page);
  await page.waitForFunction(() => document.querySelector('ladle-video-button')?.shadowRoot.querySelector('.pill.shown'));
  assert.equal(await shadow(page, '.pill > span'), 'Download video');
  assert.equal(await shadow(page, '.pill .quality'), '1080p');
  await clickShadow(page, '.pill');
  const labels = await page.evaluate(() =>
    Array.from(document.querySelector('ladle-video-button').shadowRoot.querySelectorAll('.opt'), (o) => ({
      text: o.querySelector('b').textContent,
      checked: o.getAttribute('aria-checked'),
      format: o.querySelector('.label span').textContent,
    }))
  );
  assert.deepEqual(labels.map((l) => l.text), ['2160p · 4K', '1080p', '720p', 'Audio only']);
  assert.deepEqual(labels.map((l) => l.checked), ['false', 'true', 'false', 'false']);
  assert.equal(labels[3].format, 'M4A · AAC');
  assert.equal(await shadow(page, '.go'), 'Download 1080p');
  if (shots) {
    mkdirSync(shots, { recursive: true });
    await page.screenshot({ path: `${shots}/video-menu.png` });
  }
  await clickShadow(page, '.opt[data-index="2"]');
  assert.equal(await shadow(page, '.go'), 'Download 720p');
  await page.close();
});

test('protected video shows the disabled pill', async () => {
  const page = await open('/video.html', {
    getConfig: { interceptClicks: false },
    inspectVideo: { options: [{ label: 'Original', format: 'MP4', url: 'http://x/clip.mp4', kind: 'file' }] },
  });
  await page.evaluate(() => document.getElementById('v').dispatchEvent(new Event('encrypted')));
  await hoverVideo(page);
  await page.waitForFunction(() => document.querySelector('ladle-video-button')?.shadowRoot.querySelector('.pill.locked.shown'));
  assert.equal(await shadow(page, '.pill'), 'Protected video can’t be saved');
  const isButton = await page.evaluate(() => document.querySelector('ladle-video-button').shadowRoot.querySelector('.pill').tagName);
  assert.equal(isButton, 'SPAN', 'nothing to click');
  if (shots) await page.screenshot({ path: `${shots}/video-protected.png` });
  await page.close();
});

test('an encrypted stream reported by the background is protected too', async () => {
  const page = await open('/hls.html', { getConfig: { interceptClicks: false }, inspectVideo: { protected: true } });
  await hoverVideo(page);
  await page.waitForFunction(() => document.querySelector('ladle-video-button')?.shadowRoot.querySelector('.pill.locked'));
  assert.equal(await shadow(page, '.pill'), 'Protected video can’t be saved');
  await page.close();
});

test('nothing to save means no pill', async () => {
  const page = await open('/hls.html', { getConfig: { interceptClicks: false }, inspectVideo: { unavailable: true } });
  await hoverVideo(page);
  await page.waitForFunction(() => window.__sent.some((m) => m.type === 'inspectVideo'));
  await page.waitForTimeout(100);
  assert.equal(await shadow(page, '.pill'), null);
  await page.close();
});

test('⌥ Option-click is reported so the browser keeps that download', async () => {
  const page = await open('/links.html', { getConfig: { interceptClicks: false } });
  await page.evaluate(() => {
    document.getElementById('zip').addEventListener('click', (e) => e.preventDefault());
  });
  await page.click('#zip', { modifiers: ['Alt'] });
  const clicks = await sent(page, 'altClick');
  assert.equal(clicks.length, 1);
  assert.match(clicks[0].url, /\/files\/archive\.zip$/);
  await page.close();
});

test('Safari mode hands clicks on watched files to Ladle', async () => {
  const page = await open('/links.html', {
    getConfig: { interceptClicks: true, catchTypes: ['dmg', 'zip', 'pdf'] },
    catchLink: { ok: true },
  });
  await page.waitForFunction(() => window.__sent.some((m) => m.type === 'getConfig'));
  await page.waitForTimeout(50);
  await page.click('#dmg');
  await page.waitForFunction(() => window.__sent.some((m) => m.type === 'catchLink'));
  const [caught] = await sent(page, 'catchLink');
  assert.match(caught.url, /HandBrake-1\.8\.2\.dmg$/);
  assert.match(caught.referrer, /\/links\.html$/);
  assert.equal(caught.cookies, 'session=abc123', 'same-host cookies come along');
  assert.match(page.url(), /links\.html$/, 'the page stays put');
  // ⌥-click and ordinary pages are left to the browser.
  await page.evaluate(() => {
    for (const a of document.querySelectorAll('a')) a.addEventListener('click', (e) => e.preventDefault());
  });
  await page.click('#zip', { modifiers: ['Alt'] });
  await page.click('#page');
  assert.equal((await sent(page, 'catchLink')).length, 1);
  await page.close();
});

test('collects links for "Download All Links with Ladle…"', async () => {
  const page = await open('/links.html', { getConfig: { interceptClicks: false } });
  const all = await page.evaluate(() => {
    let reply;
    window.__listeners[0]({ type: 'collectLinks', selectionOnly: false }, {}, (r) => (reply = r));
    return reply.links;
  });
  assert.deepEqual(
    all.map((u) => new URL(u).pathname),
    ['/files/HandBrake-1.8.2.dmg', '/files/archive.zip', '/other.html', '/files/report.pdf']
  );
  const selected = await page.evaluate(() => {
    const range = document.createRange();
    range.selectNodeContents(document.getElementById('part'));
    getSelection().removeAllRanges();
    getSelection().addRange(range);
    let reply;
    window.__listeners[0]({ type: 'collectLinks', selectionOnly: true }, {}, (r) => (reply = r));
    return reply.links;
  });
  assert.deepEqual(selected.map((u) => new URL(u).pathname), ['/files/report.pdf']);
  await page.waitForFunction(() => window.__sent.some((m) => m.type === 'pageCount'));
  const [count] = await sent(page, 'pageCount');
  assert.equal(count.count, 3, 'the toolbar badge counts links to files');
  await page.close();
});
