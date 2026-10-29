// Checks the built site in dist/:
//   1. every internal link and #anchor resolves to a real page and element;
//   2. every URL and docs path that SPEC.md says the app links to exists, with its anchors;
//   3. the changelog has an anchor for the version in SPEC.md;
//   4. the update feed is a Sparkle RSS file.
// Run after `npm run build`:  npm run check

import { readFile, readdir, stat } from 'node:fs/promises';
import { existsSync } from 'node:fs';
import { join, relative, resolve, sep } from 'node:path';
import { fileURLToPath } from 'node:url';

const siteDir = resolve(fileURLToPath(new URL('..', import.meta.url)));
const dist = join(siteDir, 'dist');
const specPath = resolve(siteDir, '..', 'SPEC.md');
const SITE_HOSTS = new Set(['ladle.alirazakhan.me']);

if (!existsSync(dist)) {
	console.error('dist/ not found. Run `npm run build` first.');
	process.exit(1);
}

const errors = [];
const external = new Map();

const decode = (value) =>
	value
		.replace(/&quot;/g, '"')
		.replace(/&#39;|&#x27;/g, "'")
		.replace(/&lt;/g, '<')
		.replace(/&gt;/g, '>')
		.replace(/&amp;/g, '&');

async function walk(dir) {
	const out = [];
	for (const entry of await readdir(dir, { withFileTypes: true })) {
		const full = join(dir, entry.name);
		if (entry.isDirectory()) out.push(...(await walk(full)));
		else out.push(full);
	}
	return out;
}

/** URL path for a built HTML file: dist/docs/x/index.html -> /docs/x/ */
function pagePath(file) {
	const rel = relative(dist, file).split(sep).join('/');
	if (rel === 'index.html') return '/';
	if (rel.endsWith('/index.html')) return `/${rel.slice(0, -'index.html'.length)}`;
	return `/${rel}`;
}

const files = await walk(dist);
const htmlFiles = files.filter((f) => f.endsWith('.html'));
const pages = new Map();

for (const file of htmlFiles) {
	const html = await readFile(file, 'utf8');
	const ids = new Set();
	for (const m of html.matchAll(/<[a-zA-Z][^>]*?\s(?:id|name)=(?:"([^"]*)"|'([^']*)'|([^\s>]+))/g)) {
		ids.add(decode(m[1] ?? m[2] ?? m[3]));
	}
	const links = [];
	for (const tag of html.matchAll(/<(a|link|script|img|source|iframe|meta)\b[^>]*>/gi)) {
		const text = tag[0];
		const name = tag[1].toLowerCase();
		const attr =
			name === 'a' || name === 'link' ? 'href' : name === 'meta' ? 'content' : 'src';
		const m = text.match(new RegExp(`\\s${attr}=(?:"([^"]*)"|'([^']*)'|([^\\s>]+))`, 'i'));
		if (!m) continue;
		const value = decode(m[1] ?? m[2] ?? m[3]);
		if (name === 'meta' && !/^https?:\/\//.test(value)) continue;
		if (name === 'link' && /\brel=["']?(preconnect|dns-prefetch)/i.test(text)) continue;
		links.push(value);
	}
	pages.set(pagePath(file), { file, ids, links });
}

/** Resolves a site path to a file in dist, following GitHub Pages' rules. */
function resolveTarget(pathname) {
	const clean = decodeURIComponent(pathname);
	if (clean.endsWith('/')) {
		return pages.has(clean) ? { page: pages.get(clean) } : null;
	}
	const file = join(dist, ...clean.split('/').filter(Boolean));
	if (existsSync(file)) return { file };
	if (pages.has(`${clean}/`)) return { page: pages.get(`${clean}/`), missingSlash: true };
	return null;
}

function checkLink(from, raw) {
	if (!raw || /^(mailto|tel|javascript|data|blob):/i.test(raw)) return;
	let url;
	try {
		url = new URL(raw, `https://ladle.alirazakhan.me${from}`);
	} catch {
		errors.push(`${from}: unparseable link "${raw}"`);
		return;
	}
	if (!SITE_HOSTS.has(url.host)) {
		const key = `${url.origin}${url.pathname}${url.search ? ' (with a query)' : ''}`;
		const list = external.get(key) ?? new Set();
		list.add(from);
		external.set(key, list);
		return;
	}
	const target = resolveTarget(url.pathname);
	if (!target) {
		errors.push(`${from}: broken link ${raw}`);
		return;
	}
	if (target.missingSlash) errors.push(`${from}: link ${raw} is missing its trailing slash`);
	const hash = decodeURIComponent(url.hash.slice(1));
	if (hash && target.page && !target.page.ids.has(hash)) {
		errors.push(`${from}: link ${raw} points to a missing #${hash}`);
	}
}

for (const [path, { links }] of pages) {
	for (const link of links) checkLink(path, link);
}

// SPEC.md: URLs, the docs pages the app opens, and the changelog anchor format.
let specChecks = 0;
if (existsSync(specPath)) {
	const spec = await readFile(specPath, 'utf8');
	const required = new Map();
	const add = (path, anchor) => {
		const set = required.get(path) ?? new Set();
		if (anchor) set.add(anchor);
		required.set(path, set);
	};
	for (const m of spec.matchAll(/https:\/\/ladle\.alirazakhan\.me(\/[^\s`)|]*)/g)) {
		const url = new URL(m[1], 'https://ladle.alirazakhan.me');
		add(url.pathname, decodeURIComponent(url.hash.slice(1)));
	}
	const block = spec.split('### Docs pages the app links to')[1]?.split('```')[1] ?? '';
	for (const line of block.split('\n')) {
		const m = line.match(/^\s*(\/docs\/\S*)/);
		if (!m) continue;
		const anchors = line.match(/anchors:\s*(.*)$/)?.[1].match(/#[\w-]+/g) ?? [];
		add(m[1]);
		for (const anchor of anchors) add(m[1], anchor.slice(1));
	}
	const version = spec.match(/\|\s*Version\s*\|\s*([\d.]+)/)?.[1];
	if (version) add('/changelog/', `v${version.replace(/\./g, '-')}`);

	for (const [path, anchors] of required) {
		specChecks++;
		const target = resolveTarget(path);
		if (!target || target.missingSlash) {
			errors.push(`SPEC.md: ${path} is not published`);
			continue;
		}
		for (const anchor of anchors) {
			specChecks++;
			if (!target.page?.ids.has(anchor)) errors.push(`SPEC.md: ${path} has no #${anchor}`);
		}
	}
} else {
	console.warn(`Skipped SPEC.md checks: ${specPath} not found.`);
}

// The update feed must stay a Sparkle RSS file the app can read.
const appcast = await readFile(join(dist, 'appcast.xml'), 'utf8').catch(() => '');
if (!/<rss[^>]*version="2\.0"/.test(appcast) || !appcast.includes('xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle"') || !/<channel>[\s\S]*<title>/.test(appcast)) {
	errors.push('appcast.xml is missing or is not a Sparkle RSS 2.0 feed');
}

const assetCount = files.length - htmlFiles.length;
console.log(`Checked ${htmlFiles.length} pages (${assetCount} other files) and ${specChecks} SPEC.md requirements.`);
console.log(`External links (not fetched): ${external.size}`);
for (const [href, from] of [...external].sort()) console.log(`  ${href}  (${from.size} page${from.size === 1 ? '' : 's'})`);

if (errors.length) {
	console.error(`\n${errors.length} problem${errors.length === 1 ? '' : 's'}:`);
	for (const error of errors) console.error(`  ✗ ${error}`);
	process.exit(1);
}
console.log('\nAll internal links, anchors and SPEC.md pages resolve.');
