// Product facts and URLs shared by every page. These mirror SPEC.md at the repository root;
// the app hard-codes the same URLs, so change them there first.

export const SITE_URL = 'https://ladle.alirazakhan.me';

/** Always points at the newest release, so the site never needs a new link per version. */
export const DMG_URL = 'https://github.com/ALIRAZA47/ladle-mac/releases/latest/download/Ladle.dmg';
export const RELEASES_URL = 'https://github.com/ALIRAZA47/ladle-mac/releases';
export const SUPPORT_URL = 'https://github.com/ALIRAZA47/ladle-mac/issues';
export const APPCAST_URL = `${SITE_URL}/appcast.xml`;

/** Used when neither the appcast nor the changelog names a version. */
export const FALLBACK_VERSION = '1.0.0';

export const REQUIREMENTS = 'macOS 14 Sonoma or later';
export const CHIPS = 'Apple silicon and Intel';

/** Changelog anchors are `v` + the version with dots as dashes, e.g. 1.0.0 → #v1-0-0. */
export function versionAnchor(version) {
	return `v${String(version).trim().replace(/\./g, '-')}`;
}

/** A GitHub "new issue" link with the title and body filled in. */
export function newIssueUrl(title, body) {
	const params = new URLSearchParams({ title, body });
	return `${SUPPORT_URL}/new?${params.toString()}`;
}
