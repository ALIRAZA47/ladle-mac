#!/usr/bin/env node
// Renders Ladle's icons from the brand artwork (a molten arrow pouring into a steel ladle on a
// graphite squircle) with Chromium via Playwright:
//   - Ladle/Assets.xcassets/AppIcon.appiconset   (16–1024 px, simpler artwork at small sizes)
//   - Ladle/Assets.xcassets/MenuBarIcon.imageset (template glyph, 18 pt @1x/@2x)
//   - BrowserExtension/src/icons                 (extension and toolbar icons)
//
//   cd app/BrowserExtension && npm install && node ../scripts/render-icons.mjs

import { mkdirSync, writeFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { createRequire } from 'node:module';

const here = dirname(fileURLToPath(import.meta.url));
const app = join(here, '..');
const require = createRequire(join(app, 'BrowserExtension', 'package.json'));
const { chromium } = require('playwright');

const DEFS = `
  <radialGradient id="glow" cx="0.5" cy="0.5" r="0.5"><stop offset="0" stop-color="#FF8A1F" stop-opacity="0.5"/><stop offset="1" stop-color="#FF8A1F" stop-opacity="0"/></radialGradient>
  <linearGradient id="steel" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stop-color="#F1F3F5"/><stop offset="0.55" stop-color="#A9B0B8"/><stop offset="1" stop-color="#6A7179"/></linearGradient>
  <radialGradient id="molten" cx="0.5" cy="0.45" r="0.6"><stop offset="0" stop-color="#FFE6A8"/><stop offset="0.45" stop-color="#FFB04A"/><stop offset="1" stop-color="#FF4F1A"/></radialGradient>
  <linearGradient id="pour" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stop-color="#FFD27A"/><stop offset="0.6" stop-color="#FF8A1F"/><stop offset="1" stop-color="#FF4F1A"/></linearGradient>
  <linearGradient id="graphite" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stop-color="#34302B"/><stop offset="0.55" stop-color="#1B1917"/><stop offset="1" stop-color="#0E0D0C"/></linearGradient>
  <linearGradient id="sheen" x1="0.18" y1="0" x2="0.62" y2="1"><stop offset="0" stop-color="#FFFFFF" stop-opacity="0.12"/><stop offset="0.38" stop-color="#FFFFFF" stop-opacity="0"/></linearGradient>
`;

/** The artwork in a 240-unit box, as on the Brand board: full detail, medium (≈52 px) and small (≈28 px). */
function artwork(detail) {
  const arrow = 'M106 46V104M84 84l22 22 22-22';
  if (detail === 'small') {
    return `
      <path d="M48 138A58 58 0 0 0 164 138Z" fill="url(#steel)"/>
      <ellipse cx="106" cy="138" rx="58" ry="13" fill="url(#molten)"/>
      <path d="M158 131C168 110 179 87 186 67" fill="none" stroke="#CDD2D7" stroke-width="16" stroke-linecap="round"/>
      <path d="${arrow}" fill="none" stroke="#FF8A1F" stroke-width="20" stroke-linecap="round" stroke-linejoin="round"/>`;
  }
  if (detail === 'medium') {
    return `
      <circle cx="106" cy="138" r="84" fill="url(#glow)"/>
      <path d="M48 138A58 58 0 0 0 164 138Z" fill="url(#steel)"/>
      <ellipse cx="106" cy="138" rx="58" ry="13" fill="url(#molten)"/>
      <path d="M158 131C168 110 179 87 186 67" fill="none" stroke="#CDD2D7" stroke-width="13" stroke-linecap="round"/>
      <path d="${arrow}" fill="none" stroke="url(#pour)" stroke-width="16" stroke-linecap="round" stroke-linejoin="round"/>`;
  }
  return `
    <circle cx="106" cy="138" r="84" fill="url(#glow)"/>
    <path d="M48 138A58 58 0 0 0 164 138Z" fill="url(#steel)"/>
    <ellipse cx="106" cy="138" rx="58" ry="13" fill="url(#molten)"/>
    <path d="M158 131C168 110 179 87 186 67" fill="none" stroke="#CDD2D7" stroke-width="12" stroke-linecap="round"/>
    <circle cx="189" cy="56" r="10" fill="none" stroke="#CDD2D7" stroke-width="6"/>
    <path d="${arrow}" fill="none" stroke="#FF8A1F" stroke-opacity="0.28" stroke-width="30" stroke-linecap="round" stroke-linejoin="round"/>
    <path d="${arrow}" fill="none" stroke="url(#pour)" stroke-width="14" stroke-linecap="round" stroke-linejoin="round"/>`;
}

function detailFor(pixels) {
  if (pixels <= 40) return 'small';
  if (pixels <= 80) return 'medium';
  return 'full';
}

/**
 * The app icon at `size` px. `inset` is the share of the canvas the squircle fills
 * (macOS icons leave a margin for the shadow: 824 of 1024).
 */
function iconSVG(size, inset, withShadow) {
  const body = size * inset;
  const offset = (size - body) / 2;
  const radius = body * 0.2245;
  const scale = body / 240;
  const detail = detailFor(body);
  const shadow = withShadow
    ? `<filter id="shadow" x="-20%" y="-20%" width="140%" height="150%"><feDropShadow dx="0" dy="${(size * 0.012).toFixed(2)}" stdDeviation="${(size * 0.014).toFixed(2)}" flood-color="#000" flood-opacity="0.38"/></filter>`
    : '';
  const highlight = body >= 64
    ? `<rect x="${offset + 0.5}" y="${offset + 0.5}" width="${body - 1}" height="${body - 1}" rx="${radius}" fill="none" stroke="#FFFFFF" stroke-opacity="0.07" stroke-width="${Math.max(1, size / 512)}"/>`
    : '';
  return `<svg xmlns="http://www.w3.org/2000/svg" width="${size}" height="${size}" viewBox="0 0 ${size} ${size}">
    <defs>${DEFS}${shadow}<clipPath id="clip"><rect x="${offset}" y="${offset}" width="${body}" height="${body}" rx="${radius}"/></clipPath></defs>
    <rect x="${offset}" y="${offset}" width="${body}" height="${body}" rx="${radius}" fill="url(#graphite)" ${withShadow ? 'filter="url(#shadow)"' : ''}/>
    <g clip-path="url(#clip)">
      <g transform="translate(${offset} ${offset}) scale(${scale})">${artwork(detail)}</g>
      <rect x="${offset}" y="${offset}" width="${body}" height="${body}" fill="url(#sheen)"/>
    </g>
    ${highlight}
  </svg>`;
}

/** The outline ladle glyph used in the interface (24-unit box, 1.8 stroke). */
function glyphSVG(size, color, strokeWidth = 1.8) {
  return `<svg xmlns="http://www.w3.org/2000/svg" width="${size}" height="${size}" viewBox="0 0 24 24" fill="none" stroke="${color}" stroke-width="${strokeWidth}" stroke-linecap="round" stroke-linejoin="round">
    <path d="M3 12.5h13a6.5 6.5 0 0 1-13 0z"/><path d="M16 12.5l5-7"/><path d="M9.5 2.5v6M7 6.5l2.5 2.5L12 6.5"/></svg>`;
}

async function render(page, svg, size, file) {
  await page.setViewportSize({ width: size, height: size });
  await page.setContent(`<!doctype html><html><head><style>html,body{margin:0;background:transparent}svg{display:block}</style></head><body>${svg}</body></html>`);
  const png = await page.screenshot({ omitBackground: true, clip: { x: 0, y: 0, width: size, height: size } });
  mkdirSync(dirname(file), { recursive: true });
  writeFileSync(file, png);
}

const browser = await chromium.launch();
const page = await browser.newPage({ deviceScaleFactor: 1 });

// macOS app icon.
const appIcon = join(app, 'Ladle', 'Assets.xcassets', 'AppIcon.appiconset');
const images = [];
for (const points of [16, 32, 128, 256, 512]) {
  for (const scale of [1, 2]) {
    const pixels = points * scale;
    const filename = `icon_${points}x${points}${scale === 2 ? '@2x' : ''}.png`;
    await render(page, iconSVG(pixels, 824 / 1024, pixels >= 64), pixels, join(appIcon, filename));
    images.push({ size: `${points}x${points}`, idiom: 'mac', filename, scale: `${scale}x` });
  }
}
writeFileSync(join(appIcon, 'Contents.json'), JSON.stringify({ images, info: { version: 1, author: 'xcode' } }, null, 2) + '\n');

// Menu bar: a template image (black + alpha); macOS tints it.
const menuBar = join(app, 'Ladle', 'Assets.xcassets', 'MenuBarIcon.imageset');
await render(page, glyphSVG(18, '#000000'), 18, join(menuBar, 'MenuBarIcon.png'));
await render(page, glyphSVG(36, '#000000'), 36, join(menuBar, 'MenuBarIcon@2x.png'));
writeFileSync(
  join(menuBar, 'Contents.json'),
  JSON.stringify(
    {
      images: [
        { idiom: 'mac', filename: 'MenuBarIcon.png', scale: '1x' },
        { idiom: 'mac', filename: 'MenuBarIcon@2x.png', scale: '2x' },
      ],
      info: { version: 1, author: 'xcode' },
      properties: { 'template-rendering-intent': 'template' },
    },
    null,
    2
  ) + '\n'
);

// Browser extension.
const icons = join(app, 'BrowserExtension', 'src', 'icons');
for (const size of [16, 32, 48, 96, 128]) {
  await render(page, iconSVG(size, size <= 32 ? 1 : 0.875, false), size, join(icons, `icon-${size}.png`));
}
for (const size of [16, 32]) {
  await render(page, glyphSVG(size, '#FF8A1F', 2), size, join(icons, `toolbar-${size}.png`));
}

await browser.close();
console.log('Icons rendered.');
