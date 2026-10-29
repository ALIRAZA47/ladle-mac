import { test } from 'node:test';
import assert from 'node:assert/strict';
import { execFileSync } from 'node:child_process';
import { readFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { inflateRawSync } from 'node:zlib';

const root = join(dirname(fileURLToPath(import.meta.url)), '..', '..');

/** name → contents, read through the zip's central directory. */
function unzip(path) {
  const data = readFileSync(path);
  const end = data.lastIndexOf(Buffer.from([0x50, 0x4b, 0x05, 0x06]));
  const count = data.readUInt16LE(end + 10);
  let offset = data.readUInt32LE(end + 16);
  const files = new Map();
  for (let i = 0; i < count; i += 1) {
    const packedSize = data.readUInt32LE(offset + 20);
    const nameLength = data.readUInt16LE(offset + 28);
    const extraLength = data.readUInt16LE(offset + 30);
    const commentLength = data.readUInt16LE(offset + 32);
    const local = data.readUInt32LE(offset + 42);
    const name = data.toString('utf8', offset + 46, offset + 46 + nameLength);
    const start = local + 30 + data.readUInt16LE(local + 26) + data.readUInt16LE(local + 28);
    files.set(name, inflateRawSync(data.subarray(start, start + packedSize)));
    offset += 46 + nameLength + extraLength + commentLength;
  }
  return files;
}

test('the release zip unpacks to one folder, ready for Load unpacked', () => {
  execFileSync(process.execPath, [join(root, 'build.mjs'), '--release'], { stdio: 'pipe' });
  const files = unzip(join(root, 'dist', 'Ladle-Chrome-Extension.zip'));
  for (const name of files.keys()) assert.match(name, /^Ladle-Chrome-Extension\//);
  const manifest = JSON.parse(files.get('Ladle-Chrome-Extension/manifest.json').toString('utf8'));
  assert.equal(manifest.manifest_version, 3);
  assert.ok(manifest.key, 'keeps the development key, which pins the extension ID Ladle allows');
  for (const file of ['background.js', 'content.js', 'lib/ladle-common.js', 'lib/hls.js', 'icons/icon-128.png']) {
    assert.ok(files.has('Ladle-Chrome-Extension/' + file), file);
  }
});
