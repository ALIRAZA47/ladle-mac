import { test } from 'node:test';
import assert from 'node:assert/strict';
import { createRequire } from 'node:module';
import { readFileSync } from 'node:fs';

const require = createRequire(import.meta.url);
const H = require('../../src/lib/hls.js');
const fixture = (name) => readFileSync(new URL(`../fixtures/${name}`, import.meta.url), 'utf8');
const base = 'https://videos.example.org/talks/designing-for-speed/master.m3u8';

test('parses a master playlist', () => {
  const master = H.parse(fixture('master.m3u8'), base);
  assert.equal(master.type, 'master');
  assert.equal(master.variants.length, 4, 'I-frame playlists are left out');
  assert.equal(master.protected, false);
  const labels = H.sortedVariants(master).map(H.qualityLabel);
  assert.deepEqual(labels, ['2160p · 4K', '1080p', '720p', 'Audio only']);
  assert.equal(H.sortedVariants(master)[2].uri, 'https://videos.example.org/talks/designing-for-speed/720p/index.m3u8');
  assert.equal(H.audioRendition(master, master.variants[0]).name, 'English');
});

test('builds the quality menu with sizes and Audio only', () => {
  const master = H.parse(fixture('master.m3u8'), base);
  const media = H.parse(fixture('fmp4.m3u8'), 'https://videos.example.org/talks/designing-for-speed/1080p/index.m3u8');
  const options = H.menuOptions(master, media);
  assert.deepEqual(options.map((o) => o.label), ['2160p · 4K', '1080p', '720p', 'Audio only']);
  assert.deepEqual(options.map((o) => o.format), ['MP4 · HEVC', 'MP4 · H.264', 'MP4 · H.264', 'M4A · AAC']);
  assert.equal(options[1].size, Math.round((5_000_000 * 16.5) / 8));
  assert.equal(options[2].size, Math.round((2_200_000 * 16.5) / 8), 'average bandwidth when given');
  assert.equal(options[1].audio, 'https://videos.example.org/talks/designing-for-speed/audio/en/index.m3u8');
  assert.equal(options[3].url, 'https://videos.example.org/talks/designing-for-speed/audio-only/index.m3u8');
  assert.equal(H.probeVariant(master).height, 2160);
});

test('media playlists, containers, protection and live streams', () => {
  const fmp4 = H.parse(fixture('fmp4.m3u8'), base);
  assert.equal(fmp4.type, 'media');
  assert.equal(fmp4.segments.length, 3);
  assert.equal(fmp4.duration, 16.5);
  assert.equal(fmp4.complete, true);
  assert.equal(H.container(fmp4), 'fmp4');
  const ts = H.parse(fixture('ts.m3u8'), base);
  assert.equal(ts.protected, false, 'METHOD=NONE is fine');
  assert.equal(H.container(ts), 'ts');
  assert.equal(H.parse(fixture('encrypted.m3u8'), base).protected, true);
  assert.equal(H.parse(fixture('live.m3u8'), base).complete, false);
  const withSessionKey = fixture('master.m3u8').replace('#EXT-X-INDEPENDENT-SEGMENTS', '#EXT-X-SESSION-KEY:METHOD=SAMPLE-AES,URI="skd://k"');
  assert.equal(H.parse(withSessionKey, base).protected, true);
  assert.throws(() => H.parse('<html></html>', base));
});

test('TS streams are labelled TS', () => {
  const master = H.parse(fixture('master.m3u8'), base);
  const ts = H.parse(fixture('ts.m3u8'), base);
  const options = H.menuOptions(master, ts);
  assert.equal(options[1].format, 'TS · H.264');
  assert.equal(options[3].format, 'TS · AAC');
});

test('attribute lists keep quoted commas', () => {
  const a = H.attributes('BANDWIDTH=1,CODECS="avc1.64001f,mp4a.40.2",RESOLUTION=1280x720');
  assert.equal(a.CODECS, 'avc1.64001f,mp4a.40.2');
  assert.equal(a.RESOLUTION, '1280x720');
});
