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
  assert.equal(manifest.version, '0.1.0');
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
  await page.mouse.move(50, 50);
  await page.mouse.move(400, 250, { steps: 4 });
  // The content script runs in its own world; its shadow root is still reachable from the page.
  await page.waitForFunction(() => document.querySelector('ladle-video-button')?.shadowRoot.querySelector('.pill.shown .quality'), null, { timeout: 15000 });
  const quality = await page.evaluate(() => document.querySelector('ladle-video-button').shadowRoot.querySelector('.pill .quality').textContent);
  assert.equal(quality, '1080p');
  await page.evaluate(() => document.querySelector('ladle-video-button').shadowRoot.querySelector('.pill').click());
  await page.evaluate(() => document.querySelector('ladle-video-button').shadowRoot.querySelector('.go').click());
  const video = await waitFor(() => messages().find((m) => m.type === 'video'));
  assert.ok(video, 'the video was handed to Ladle');
  assert.equal(video.kind, 'hls');
  assert.equal(video.url, site.origin + '/media/1080p/index.m3u8');
  assert.equal(video.audio, site.origin + '/media/audio/en/index.m3u8');
  assert.equal(video.quality, '1080p');
  assert.equal(video.title, 'Designing for Speed');
  assert.equal(video.referrer, site.origin + '/hls-native.html');
  await page.close();
});

test('pages that are not files are never touched', async () => {
  const page = await context.newPage();
  await page.goto(site.origin + '/links.html');
  await page.click('#page');
  await page.waitForURL(/other\.html$/);
  await page.close();
});
