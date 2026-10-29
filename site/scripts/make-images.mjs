// Regenerates the icons and the social preview image in public/ from the app icon artwork.
//
//   npm run images
//
// Commit the results. Sources:
//   src/assets/ladle-icon.svg  full-detail icon  -> public/apple-touch-icon.png
//   public/favicon.svg         small-size icon   -> public/favicon.ico (16, 32, 48 px)
//   scripts/og.html            1200×630 card      -> public/og.png (needs Playwright's Chromium)

import { readFile, writeFile } from 'node:fs/promises';
import { createRequire } from 'node:module';
import { fileURLToPath, pathToFileURL } from 'node:url';
import sharp from 'sharp';

const path = (relative) => fileURLToPath(new URL(relative, import.meta.url));

/** Packs PNG images into a .ico file (PNG-compressed entries, supported everywhere today). */
function toIco(images) {
	const header = Buffer.alloc(6);
	header.writeUInt16LE(0, 0);
	header.writeUInt16LE(1, 2);
	header.writeUInt16LE(images.length, 4);
	const directory = Buffer.alloc(16 * images.length);
	let offset = header.length + directory.length;
	images.forEach(({ size, png }, i) => {
		const at = i * 16;
		directory.writeUInt8(size >= 256 ? 0 : size, at);
		directory.writeUInt8(size >= 256 ? 0 : size, at + 1);
		directory.writeUInt8(0, at + 2);
		directory.writeUInt8(0, at + 3);
		directory.writeUInt16LE(1, at + 4);
		directory.writeUInt16LE(32, at + 6);
		directory.writeUInt32LE(png.length, at + 8);
		directory.writeUInt32LE(offset, at + 12);
		offset += png.length;
	});
	return Buffer.concat([header, directory, ...images.map(({ png }) => png)]);
}

const render = (svg, size) =>
	sharp(svg, { density: 384 }).resize(size, size, { kernel: 'lanczos3' }).png({ compressionLevel: 9 }).toBuffer();

// favicon.ico from the heavier small-size artwork, which stays legible at 16 px.
const small = await readFile(path('../public/favicon.svg'));
const icoImages = await Promise.all([16, 32, 48].map(async (size) => ({ size, png: await render(small, size) })));
await writeFile(path('../public/favicon.ico'), toIco(icoImages));
console.log('wrote public/favicon.ico');

// apple-touch-icon.png: square and full-bleed, because iOS rounds the corners itself.
const full = (await readFile(path('../src/assets/ladle-icon.svg'), 'utf8'))
	.replace('<rect width="240" height="240" rx="55"/>', '<rect width="240" height="240"/>')
	.replace(/<rect x="0\.75"[^>]*\/>/, '');
await writeFile(path('../public/apple-touch-icon.png'), await render(Buffer.from(full), 180));
console.log('wrote public/apple-touch-icon.png');

// og.png: rendered by Chromium so it uses the site's own fonts.
let chromium;
try {
	({ chromium } = createRequire(import.meta.url)('playwright'));
} catch {
	console.warn('Skipped public/og.png: install Playwright (npm i -D playwright && npx playwright install chromium) to render it.');
	process.exit(0);
}
const browser = await chromium.launch();
const page = await browser.newPage({ viewport: { width: 1200, height: 630 }, deviceScaleFactor: 1 });
await page.goto(pathToFileURL(path('./og.html')).href);
await page.evaluate(() => document.fonts.ready);
const shot = await page.screenshot({ type: 'png' });
await browser.close();
await writeFile(path('../public/og.png'), await sharp(shot).png({ compressionLevel: 9, palette: false }).toBuffer());
console.log('wrote public/og.png');
