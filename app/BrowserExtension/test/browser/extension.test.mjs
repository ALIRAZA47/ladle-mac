// The built Chrome extension, loaded into Chromium, talking to a stand-in native messaging host.
import { test, before, after } from 'node:test';
import assert from 'node:assert/strict';
import { createRequire } from 'node:module';
import { chmodSync, existsSync, mkdtempSync, readFileSync, rmSync, writeFileSync, mkdirSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { startServer } from './server.mjs';

const require = createRequire(import.meta.url);
const { chromium } = require('playwright');

const extensionDir = fileURLToPath(new URL('../../dist/chrome', import.meta.url));
// The ID that the development key in manifests/chrome.json gives the unpacked extension.
const EXTENSION_ID = 'pleopllngomokgfeebgjmnkjhebmcmkk';

let site;
let context;
let workspace;
let logFile;

const HOST = `#!/usr/bin/env node
// Stand-in for LadleBridge: logs each message and answers like the app would.
const fs = require('fs');
const log = ${JSON.stringify('LOGFILE')};
let buffer = Buffer.alloc(0);
function reply(obj) {
  const json = Buffer.from(JSON.stringify(obj));
  const head = Buffer.alloc(4);
  head.writeUInt32LE(json.length, 0);
  process.stdout.write(Buffer.concat([head, json]));
}
process.stdin.on('data', (chunk) => {
  buffer = Buffer.concat([buffer, chunk]);
  while (buffer.length >= 4) {
    const length = buffer.readUInt32LE(0);
    if (buffer.length < 4 + length) break;
    const msg = JSON.parse(buffer.subarray(4, 4 + length).toString());
    buffer = buffer.subarray(4 + length);
    fs.appendFileSync(log, JSON.stringify(msg) + '\\n');
    if (msg.type === 'hello') {
      reply({ replyTo: msg.id, ok: true, settings: { catchTypes: ['zip', 'dmg'], askBeforeDownloading: true, alwaysTypes: [], saveFolder: 'Downloads › Ladle', videoFolder: 'Downloads › Ladle › Video', appVersion: '1.0.0', token: 't' } });
    } else {
      reply({ replyTo: msg.id, ok: true });
    }
  }
});
process.stdin.on('end', () => process.exit(0));
`;

function messages() {
  if (!existsSync(logFile)) return [];
  return readFileSync(logFile, 'utf8').trim().split('\n').filter(Boolean).map((line) => JSON.parse(line));
}

async function waitFor(check, timeout = 15000) {
  const end = Date.now() + timeout;
  while (Date.now() < end) {
    const value = check();
    if (value) return value;
    await new Promise((r) => setTimeout(r, 100));
  }
  return null;
}

/** Hovers the fixture pages' video (at 40,40, 680×383) with the real mouse. */
async function hoverVideo(page) {
  await page.mouse.move(50, 50);
  await page.mouse.move(400, 250, { steps: 4 });
}

const pillShown = (page) =>
  page.waitForFunction(() => document.querySelector('ladle-video-button')?.shadowRoot.querySelector('.pill.shown'), null, { timeout: 15000 });

const shadowText = (page, selector) =>
  page.evaluate((sel) => {
    const el = document.querySelector('ladle-video-button')?.shadowRoot.querySelector(sel);
    return el ? el.textContent.replace(/\s+/g, ' ').trim() : null;
  }, selector);

/** A real click on an element of the button's shadow root: the content script ignores synthetic ones. */
async function clickShadow(page, selector) {
  const { x, y } = await page.evaluate((sel) => {
    const r = document.querySelector('ladle-video-button').shadowRoot.querySelector(sel).getBoundingClientRect();
    return { x: r.left + r.width / 2, y: r.top + r.height / 2 };
  }, selector);
  await page.mouse.click(x, y);
}

/** What the page itself can do: fire a click event on the element. */
const fakeClick = (page, selector) =>
  page.evaluate((sel) => document.querySelector('ladle-video-button').shadowRoot.querySelector(sel).click(), selector);

const requestsSince = (index, path) => site.log.slice(index).filter((r) => r.path === path);

before(async () => {
  assert.ok(existsSync(join(extensionDir, 'manifest.json')), 'run `node build.mjs chrome` first');
  site = await startServer();
  workspace = mkdtempSync(join(tmpdir(), 'ladle-ext-'));
  logFile = join(workspace, 'host.log');
  const hostPath = join(workspace, 'fake-ladle-bridge.js');
  writeFileSync(hostPath, HOST.replace('"LOGFILE"', JSON.stringify(logFile)));
  chmodSync(hostPath, 0o755);
  const profile = join(workspace, 'profile');
  mkdirSync(join(profile, 'NativeMessagingHosts'), { recursive: true });
  writeFileSync(
    join(profile, 'NativeMessagingHosts', 'me.alirazakhan.ladle.json'),
    JSON.stringify({ name: 'me.alirazakhan.ladle', description: 'test', path: hostPath, type: 'stdio', allowed_origins: [`chrome-extension://${EXTENSION_ID}/`] })
  );
  context = await chromium.launchPersistentContext(profile, {
    channel: 'chromium',
    headless: true,
    acceptDownloads: true,
    args: [`--disable-extensions-except=${extensionDir}`, `--load-extension=${extensionDir}`],
  });
});

after(async () => {
  if (context) await context.close();
  if (site) await site.close();
  if (workspace) rmSync(workspace, { recursive: true, force: true });
});

test('the extension loads with its stable development ID', async () => {
  const worker = context.serviceWorkers()[0] || (await context.waitForEvent('serviceworker'));
  assert.equal(new URL(worker.url()).host, EXTENSION_ID);
  const manifest = await worker.evaluate(() => chrome.runtime.getManifest());
  assert.equal(manifest.name, 'Ladle');
  assert.equal(manifest.version, '0.1.1');
});

test('says hello to Ladle and catches a watched download with its cookies and referrer', async () => {
  const hello = await waitFor(() => messages().find((m) => m.type === 'hello'));
  assert.ok(hello, 'the extension greeted the native host');
  assert.equal(hello.browser, 'Chrome');
  const page = await context.newPage();
  await page.goto(site.origin + '/links.html');
  await page.waitForTimeout(300);
  const downloadEvent = page.waitForEvent('download', { timeout: 10000 }).catch(() => null);
  await page.click('#zip');
  const caught = await waitFor(() => messages().find((m) => m.type === 'download'));
  assert.ok(caught, 'the download was handed to Ladle');
  assert.equal(caught.url, site.origin + '/files/archive.zip');
  assert.equal(caught.mode, 'caught');
  assert.equal(caught.referrer, site.origin + '/links.html');
  assert.equal(caught.cookies, 'session=abc123');
  assert.equal(caught.browser, 'Chrome');
  assert.ok(caught.userAgent);
  const download = await downloadEvent;
  if (download) assert.equal(await download.failure(), 'canceled', 'the browser stopped its own copy');
  await page.close();
});

test('⌥ Option-click leaves the download to the browser', async () => {
  const page = await context.newPage();
  await page.goto(site.origin + '/links.html');
  await page.waitForTimeout(300);
  const before = messages().filter((m) => m.type === 'download').length;
  const downloadEvent = page.waitForEvent('download', { timeout: 10000 }).catch(() => null);
  await page.click('#dmg', { modifiers: ['Alt'] });
  const download = await downloadEvent;
  await page.waitForTimeout(1500);
  const after = messages().filter((m) => m.type === 'download');
  assert.equal(after.length, before, 'nothing was handed off');
  if (download) assert.equal(await download.failure(), null, 'the browser kept it');
  await page.close();
});

test('the video button inspects a stream and sends the chosen quality to Ladle', async () => {
  const page = await context.newPage();
  await page.goto(site.origin + '/hls-native.html');
  const mark = site.log.length;
  await hoverVideo(page);
  // The content script runs in its own world; its shadow root is still reachable from the page.
  await pillShown(page);
  assert.equal(await shadowText(page, '.pill .quality'), '1080p');
  // The stream is on the page's own origin, so it was read with the page's cookies: what the page could do itself.
  const probes = requestsSince(mark, '/media/1080p/index.m3u8');
  assert.equal(probes.length, 1, 'the extension looked at the best variant once');
  assert.equal(probes[0].headers.cookie, 'session=abc123');
  await clickShadow(page, '.pill');
  assert.equal(await shadowText(page, '.menu .title'), 'Save this video');
  await clickShadow(page, '.go');
  const video = await waitFor(() => messages().find((m) => m.type === 'video'));
  assert.ok(video, 'the video was handed to Ladle');
  assert.equal(video.kind, 'hls');
  assert.equal(video.url, site.origin + '/media/1080p/index.m3u8');
  assert.equal(video.audio, site.origin + '/media/audio/en/index.m3u8');
  assert.equal(video.quality, '1080p');
  assert.equal(video.title, 'Designing for Speed');
  assert.equal(video.referrer, site.origin + '/hls-native.html');
  assert.equal(video.cookies, 'session=abc123', 'the chosen download goes with the user’s cookies');
  await page.close();
});

test('the page can’t work the video button with events of its own', async () => {
  const page = await context.newPage();
  await page.goto(site.origin + '/hls-native.html');
  await page.waitForTimeout(300);
  const mark = site.log.length;
  await page.evaluate(() => document.dispatchEvent(new MouseEvent('mousemove', { bubbles: true, clientX: 400, clientY: 250 })));
  await page.waitForTimeout(1500);
  assert.equal(await shadowText(page, '.pill'), null, 'a faked move shows no button');
  assert.equal(requestsSince(mark, '/media/local-master.m3u8').length, 0, 'and has nothing looked at');
  await hoverVideo(page);
  await pillShown(page);
  const sent = messages().filter((m) => m.type === 'video').length;
  await fakeClick(page, '.pill');
  await page.waitForTimeout(300);
  assert.equal(await shadowText(page, '.menu'), null, 'a faked click opens no menu');
  await clickShadow(page, '.pill');
  assert.equal(await shadowText(page, '.go'), 'Download 1080p');
  await fakeClick(page, '.go');
  await page.waitForTimeout(1500);
  assert.equal(messages().filter((m) => m.type === 'video').length, sent, 'a faked Download sends nothing to Ladle');
  await page.close();
});

// The test server answers as localhost and as 127.0.0.1: two origins, one log.
const otherOrigin = () => site.origin.replace('localhost', '127.0.0.1');

/** Gives the other origin the session cookie (every page sets it) and checks that it is sent back. */
async function logInElsewhere(page) {
  await page.goto(otherOrigin() + '/other.html');
  await page.goto(otherOrigin() + '/other.html');
  const visits = site.log.filter((r) => r.path === '/other.html' && r.headers.host === new URL(otherOrigin()).host);
  assert.equal(visits[visits.length - 1].headers.cookie, 'session=abc123', 'the stream’s origin has a cookie to leak');
}

test('another origin’s stream is looked at without the user’s cookies', async () => {
  const page = await context.newPage();
  await logInElsewhere(page);
  await page.goto(site.origin + '/hls-cross.html');
  // Let the <video> load reach webRequest: that is what allows a look at another origin's stream.
  await page.waitForTimeout(500);
  const mark = site.log.length;
  await hoverVideo(page);
  await pillShown(page);
  assert.equal(await shadowText(page, '.pill .quality'), '1080p', 'a public stream still gets its quality menu');
  const otherHost = new URL(otherOrigin()).host;
  const requests = site.log.slice(mark).filter((r) => r.path.startsWith('/media/'));
  assert.ok(requests.some((r) => r.path === '/media/1080p/index.m3u8'), 'the extension read the stream');
  for (const r of requests) {
    assert.equal(r.headers.host, otherHost);
    assert.equal(r.headers.cookie, undefined, r.path + ' was fetched without cookies');
  }
  await page.close();
});

test('a stream only the user’s cookies can open is offered as is, for Ladle to fetch with them', async () => {
  const page = await context.newPage();
  await logInElsewhere(page);
  await page.goto(site.origin + '/hls-cross.html?gated');
  await page.waitForTimeout(500);
  const mark = site.log.length;
  const sent = messages().filter((m) => m.type === 'video').length;
  await hoverVideo(page);
  await pillShown(page);
  assert.equal(await shadowText(page, '.pill'), 'Download video', 'no quality to show: the playlist was not readable');
  const tries = requestsSince(mark, '/gated/media/local-master.m3u8');
  assert.ok(tries.length >= 1, 'the extension tried the playlist');
  for (const r of tries) assert.equal(r.headers.cookie, undefined, 'without cookies');
  await clickShadow(page, '.pill');
  assert.equal(await shadowText(page, '.go'), 'Download video');
  await clickShadow(page, '.go');
  const video = await waitFor(() => messages().filter((m) => m.type === 'video')[sent]);
  assert.ok(video, 'the video was handed to Ladle');
  assert.equal(video.url, otherOrigin() + '/gated/media/local-master.m3u8');
  assert.equal(video.kind, 'hls');
  assert.equal(video.quality, '', 'Ladle picks the quality itself');
  assert.equal(video.cookies, 'session=abc123', 'and downloads with the user’s cookies, as they chose to');
  await page.close();
});

test('pages that are not files are never touched', async () => {
  const page = await context.newPage();
  await page.goto(site.origin + '/links.html');
  await page.click('#page');
  await page.waitForURL(/other\.html$/);
  await page.close();
});
