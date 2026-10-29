import { test } from 'node:test';
import assert from 'node:assert/strict';
import { createRequire } from 'node:module';

const require = createRequire(import.meta.url);
const C = require('../../src/lib/ladle-common.js');

test('extensions from names and links', () => {
  assert.equal(C.extensionOf('HandBrake-1.8.2.dmg'), 'dmg');
  assert.equal(C.extensionOf('/Users/a/Downloads/Report.PDF'), 'pdf');
  assert.equal(C.extensionOf('https://a.org/x/ubuntu.iso?token=1#frag'), 'iso');
  assert.equal(C.extensionOf('https://a.org/download.php?file=x.zip'), 'php');
  assert.equal(C.extensionOf('https://a.org/My%20Film.mkv'), 'mkv');
  assert.equal(C.extensionOf('https://a.org/'), '');
  assert.equal(C.extensionOf('.hidden'), '');
  assert.equal(C.extensionOf(''), '');
  assert.equal(C.mimeToExtension('application/x-apple-diskimage'), 'dmg');
  assert.equal(C.mimeToExtension('application/pdf; charset=binary'), 'pdf');
  assert.equal(C.mimeToExtension('text/html'), '');
});

const settings = { catchTypes: ['dmg', 'zip', 'pdf', 'mp4'] };
const item = (extra) => Object.assign({ id: 1, url: 'https://handbrake.fr/HandBrake-1.8.2.dmg', filename: '', mime: '', state: 'in_progress' }, extra);

test('catches watched types only', () => {
  assert.deepEqual(C.shouldCatch(item(), { settings }), { catch: true, ext: 'dmg' });
  assert.equal(C.shouldCatch(item({ url: 'https://a.org/page.html' }), { settings }).reason, 'not-watched');
  assert.equal(C.shouldCatch(item({ url: 'https://a.org/get?id=3', mime: 'application/zip' }), { settings }).catch, true, 'by MIME type');
  assert.equal(C.shouldCatch(item({ url: 'https://a.org/get?id=3', filename: '/Users/a/Downloads/report.pdf' }), { settings }).catch, true, 'by the name the browser chose');
  assert.equal(C.shouldCatch(item({ url: 'https://a.org/x.iso' }), {}).catch, true, 'defaults when settings are unknown');
});

test('leaves the browser alone when it should', () => {
  const now = 1_000_000;
  assert.equal(C.shouldCatch(item({ url: 'blob:https://a.org/123' }), { settings }).reason, 'not-web');
  assert.equal(C.shouldCatch(item({ url: 'data:application/zip;base64,AAAA' }), { settings }).reason, 'not-web');
  assert.equal(C.shouldCatch(item({ incognito: true }), { settings }).reason, 'private');
  assert.equal(C.shouldCatch(item({ state: 'complete' }), { settings }).reason, 'finished');
  assert.equal(C.shouldCatch(item({ byExtensionId: 'me' }), { settings, selfId: 'me' }).reason, 'self');
  const url = item().url;
  assert.equal(C.shouldCatch(item(), { settings, now, altClicks: { [url]: now - 2000 } }).reason, 'option-click');
  assert.equal(C.shouldCatch(item(), { settings, now, altClicks: { [url]: now - 20000 } }).catch, true, 'an old ⌥-click no longer counts');
  assert.equal(C.shouldCatch(item(), { settings, now, bypass: { [url]: now + 1000 } }).reason, 'bypass');
  assert.equal(C.shouldCatch(item({ finalUrl: 'https://cdn.x/y.dmg' }), { settings, now, bypass: { 'https://cdn.x/y.dmg': now + 1 } }).reason, 'bypass');
});

test('cookie headers and messages', () => {
  assert.equal(C.cookieHeader([{ name: 'a', value: '1' }, { name: 'b', value: 'x=y' }, {}]), 'a=1; b=x=y');
  const msg = C.downloadMessage({ url: 'https://a.org/x.zip', filename: 'x.zip', referrer: '', cookies: 'a=1', size: -1, mode: 'caught' });
  assert.deepEqual(msg, { type: 'download', url: 'https://a.org/x.zip', mode: 'caught', filename: 'x.zip', cookies: 'a=1' });
});

test('ladle:// links use the same parameters as the app', () => {
  const link = C.ladleURL({ type: 'download', url: 'https://a.org/x.zip?a=1&b=2', referrer: 'https://a.org/', filename: 'x.zip', cookies: 'a=1; b=2', size: 10, browser: 'Chrome', mode: 'direct' });
  const parsed = new URL(link.replace('ladle://', 'http://'));
  assert.equal(parsed.host, 'add');
  assert.equal(parsed.searchParams.get('url'), 'https://a.org/x.zip?a=1&b=2');
  assert.equal(parsed.searchParams.get('referrer'), 'https://a.org/');
  assert.equal(parsed.searchParams.get('filename'), 'x.zip');
  assert.equal(parsed.searchParams.get('cookies'), 'a=1; b=2');
  assert.equal(parsed.searchParams.get('size'), '10');
  assert.equal(parsed.searchParams.get('source'), 'Chrome');
  assert.equal(parsed.searchParams.get('mode'), 'direct');
  const list = new URL(C.ladleURL({ type: 'links', links: ['https://a.org/1', 'https://a.org/2'] }).replace('ladle://', 'http://'));
  assert.deepEqual(list.searchParams.getAll('url'), ['https://a.org/1', 'https://a.org/2']);
  assert.equal(list.searchParams.get('mode'), 'choose', 'a page\'s links open the Add sheet');
  const video = new URL(C.ladleURL({ type: 'video', url: 'https://v.org/a.m3u8', kind: 'hls', title: 'Talk', quality: '1080p', audio: 'https://v.org/au.m3u8' }).replace('ladle://', 'http://'));
  assert.equal(video.searchParams.get('kind'), 'hls');
  assert.equal(video.searchParams.get('mode'), 'direct');
  assert.equal(video.searchParams.get('quality'), '1080p');
  assert.equal(video.searchParams.get('audio'), 'https://v.org/au.m3u8');
});

test('Safari click interception rules', () => {
  const click = { button: 0, altKey: false, metaKey: false, ctrlKey: false, shiftKey: false, defaultPrevented: false };
  const link = { href: 'https://handbrake.fr/HandBrake-1.8.2.dmg' };
  assert.equal(C.shouldInterceptClick(click, link, settings, 'https://handbrake.fr/downloads.php'), true);
  assert.equal(C.shouldInterceptClick({ ...click, altKey: true }, link, settings), false, '⌥-click goes to the browser');
  assert.equal(C.shouldInterceptClick({ ...click, metaKey: true }, link, settings), false, '⌘-click opens a tab');
  assert.equal(C.shouldInterceptClick({ ...click, button: 1 }, link, settings), false);
  assert.equal(C.shouldInterceptClick({ ...click, defaultPrevented: true }, link, settings), false);
  assert.equal(C.shouldInterceptClick(click, { href: 'https://a.org/page.html' }, settings), false);
  assert.equal(C.shouldInterceptClick(click, { href: 'https://a.org/get?id=1', download: 'notes.pdf' }, settings), true, 'the download attribute names the file');
  assert.equal(C.shouldInterceptClick(click, { href: 'javascript:void(0)' }, settings), false);
  assert.equal(C.shouldInterceptClick(click, { href: 'https://a.org/p#x.zip' }, settings, 'https://a.org/p'), false, 'same-page anchors stay');
});

test('sizes and durations match the app', () => {
  assert.equal(C.formatSize(5_790_000_000), '5.79 GB');
  assert.equal(C.formatSize(312_000_000), '312 MB');
  assert.equal(C.formatSize(18_200_000), '18.2 MB');
  assert.equal(C.formatSize(642_000_000), '642 MB');
  assert.equal(C.formatSize(1_900_000_000), '1.90 GB');
  assert.equal(C.formatSize(48_000_000), '48.0 MB');
  assert.equal(C.formatSize(640_000), '640 KB');
  assert.equal(C.formatSize(999_600_000), '1.00 GB');
  assert.equal(C.formatDuration(2538), '42:18');
  assert.equal(C.formatDuration(3723), '1:02:03');
});

test('links worth offering', () => {
  const hrefs = ['https://a.org/a.zip', 'https://a.org/a.zip#x', 'mailto:x@y.z', 'https://a.org/page', 'https://a.org/b.mp3', 'javascript:x'];
  assert.deepEqual(C.uniqueLinks(hrefs), ['https://a.org/a.zip', 'https://a.org/page', 'https://a.org/b.mp3']);
  assert.deepEqual(C.fileLinks(hrefs), ['https://a.org/a.zip', 'https://a.org/b.mp3']);
});

test('browser names', () => {
  assert.equal(C.browserName('Mozilla/5.0 (Macintosh) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/130.0 Safari/537.36'), 'Chrome');
  assert.equal(C.browserName('Mozilla/5.0 (Macintosh) AppleWebKit/537.36 Chrome/130.0 Safari/537.36 Edg/130.0'), 'Edge');
  assert.equal(C.browserName('Mozilla/5.0 (Macintosh; rv:128.0) Gecko/20100101 Firefox/128.0'), 'Firefox');
  assert.equal(C.browserName('Mozilla/5.0 (Macintosh) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Safari/605.1.15'), 'Safari');
  assert.equal(C.browserName('Chrome/130', { brave: true }), 'Brave');
});
