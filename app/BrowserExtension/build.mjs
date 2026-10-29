#!/usr/bin/env node
// Builds the Ladle extension for each browser from one source tree.
//
//   node build.mjs                 all browsers, into dist/<browser>/ plus a .zip each
//   node build.mjs chrome firefox  just those
//   node build.mjs --store         Chrome Web Store upload (drops the development "key")
//
// Safari's copy is also made by the Xcode build (see app/project.yml); this one is for checking.

import { cpSync, mkdirSync, readFileSync, readdirSync, rmSync, statSync, writeFileSync } from 'node:fs';
import { dirname, join, relative, sep } from 'node:path';
import { fileURLToPath } from 'node:url';
import { deflateRawSync } from 'node:zlib';

const here = dirname(fileURLToPath(import.meta.url));
const src = join(here, 'src');
const dist = join(here, 'dist');
const browsers = ['chrome', 'firefox', 'safari'];

const args = process.argv.slice(2);
const store = args.includes('--store');
const wanted = args.filter((a) => !a.startsWith('--'));
const targets = wanted.length ? wanted : browsers;
for (const target of targets) {
  if (!browsers.includes(target)) {
    console.error(`Unknown browser "${target}". Use: ${browsers.join(', ')}`);
    process.exit(1);
  }
}

function files(dir) {
  const out = [];
  for (const name of readdirSync(dir).sort()) {
    if (name.startsWith('.')) continue;
    const path = join(dir, name);
    if (statSync(path).isDirectory()) out.push(...files(path));
    else out.push(path);
  }
  return out;
}

// CRC-32 (IEEE), for the zip writer.
const CRC_TABLE = new Uint32Array(256).map((_, n) => {
  let c = n;
  for (let k = 0; k < 8; k += 1) c = c & 1 ? 0xedb88320 ^ (c >>> 1) : c >>> 1;
  return c >>> 0;
});
function crc32(buffer) {
  let c = 0xffffffff;
  for (const byte of buffer) c = CRC_TABLE[(c ^ byte) & 0xff] ^ (c >>> 8);
  return (c ^ 0xffffffff) >>> 0;
}

/** A minimal zip (deflate) with fixed timestamps, so builds are reproducible. */
function zip(root, outFile) {
  const locals = [];
  const centrals = [];
  let offset = 0;
  const dosTime = 0;
  const dosDate = (2026 - 1980) << 9 | 1 << 5 | 1;
  for (const path of files(root)) {
    const name = Buffer.from(relative(root, path).split(sep).join('/'));
    const data = readFileSync(path);
    const packed = deflateRawSync(data, { level: 9 });
    const crc = crc32(data);
    const local = Buffer.alloc(30);
    local.writeUInt32LE(0x04034b50, 0);
    local.writeUInt16LE(20, 4);
    local.writeUInt16LE(0x0800, 6);
    local.writeUInt16LE(8, 8);
    local.writeUInt16LE(dosTime, 10);
    local.writeUInt16LE(dosDate, 12);
    local.writeUInt32LE(crc, 14);
    local.writeUInt32LE(packed.length, 18);
    local.writeUInt32LE(data.length, 22);
    local.writeUInt16LE(name.length, 26);
    local.writeUInt16LE(0, 28);
    locals.push(local, name, packed);
    const central = Buffer.alloc(46);
    central.writeUInt32LE(0x02014b50, 0);
    central.writeUInt16LE(20, 4);
    central.writeUInt16LE(20, 6);
    central.writeUInt16LE(0x0800, 8);
    central.writeUInt16LE(8, 10);
    central.writeUInt16LE(dosTime, 12);
    central.writeUInt16LE(dosDate, 14);
    central.writeUInt32LE(crc, 16);
    central.writeUInt32LE(packed.length, 20);
    central.writeUInt32LE(data.length, 24);
    central.writeUInt16LE(name.length, 28);
    central.writeUInt32LE(offset, 42);
    centrals.push(central, name);
    offset += local.length + name.length + packed.length;
  }
  const centralSize = centrals.reduce((n, b) => n + b.length, 0);
  const end = Buffer.alloc(22);
  end.writeUInt32LE(0x06054b50, 0);
  end.writeUInt16LE(centrals.length / 2, 8);
  end.writeUInt16LE(centrals.length / 2, 10);
  end.writeUInt32LE(centralSize, 12);
  end.writeUInt32LE(offset, 16);
  writeFileSync(outFile, Buffer.concat([...locals, ...centrals, end]));
}

for (const browser of targets) {
  const out = join(dist, browser);
  rmSync(out, { recursive: true, force: true });
  mkdirSync(out, { recursive: true });
  cpSync(src, out, { recursive: true });
  const manifest = JSON.parse(readFileSync(join(here, 'manifests', `${browser}.json`), 'utf8'));
  if (store) delete manifest.key;
  writeFileSync(join(out, 'manifest.json'), JSON.stringify(manifest, null, 2) + '\n');
  const archive = join(dist, `ladle-${browser}-${manifest.version}${store && browser === 'chrome' ? '-store' : ''}.zip`);
  zip(out, archive);
  console.log(`${browser}: ${relative(here, out)}  →  ${relative(here, archive)}`);
}
