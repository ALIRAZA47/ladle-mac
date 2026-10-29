import { readFileSync } from 'node:fs';
import { resolve } from 'node:path';
import { getCollection } from 'astro:content';
import { FALLBACK_VERSION, versionAnchor } from '../config/site.mjs';

/** Compare plain x.y.z versions. */
export function compareVersions(a: string, b: string): number {
	const pa = a.split('.').map(Number);
	const pb = b.split('.').map(Number);
	for (let i = 0; i < Math.max(pa.length, pb.length); i++) {
		const diff = (pa[i] ?? 0) - (pb[i] ?? 0);
		if (diff !== 0) return diff;
	}
	return 0;
}

/** Versions listed in a Sparkle appcast, in either the element or the attribute form. */
export function appcastVersions(xml: string): string[] {
	const items = xml.match(/<item\b[\s\S]*?<\/item>/g) ?? [];
	return items
		.map(
			(item) =>
				item.match(/<sparkle:shortVersionString>\s*([^<\s]+)\s*<\/sparkle:shortVersionString>/)?.[1] ??
				item.match(/sparkle:shortVersionString="([^"]+)"/)?.[1]
		)
		.filter((v): v is string => Boolean(v && /^\d+(\.\d+)*$/.test(v)));
}

function readAppcast(): string {
	// The release workflow rewrites public/appcast.xml; the build runs from the site folder.
	try {
		return readFileSync(resolve(process.cwd(), 'public/appcast.xml'), 'utf8');
	} catch {
		return '';
	}
}

/** Changelog entries, newest first. */
export async function changelogEntries() {
	const entries = await getCollection('changelog');
	return entries.sort((a, b) => compareVersions(b.data.version, a.data.version));
}

/**
 * The newest released version: from the update feed once releases exist, otherwise from the
 * changelog, otherwise the fallback in config.
 */
export async function latestRelease() {
	const entries = await changelogEntries();
	const fromFeed = appcastVersions(readAppcast()).sort(compareVersions).at(-1);
	const version = fromFeed ?? entries[0]?.data.version ?? FALLBACK_VERSION;
	const hasNotes = entries.some((entry) => entry.data.version === version);
	return {
		version,
		notesHref: hasNotes ? `/changelog/#${versionAnchor(version)}` : '/changelog/',
	};
}
