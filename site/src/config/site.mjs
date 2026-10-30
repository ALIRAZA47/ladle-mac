// Product facts and URLs shared by every page. These mirror SPEC.md at the repository root;
// the app hard-codes the same URLs, so change them there first.

export const SITE_URL = 'https://ladle.alirazakhan.me';

// Downloads always point at the newest release, so the site never needs a new link per version.
// Release assets have version-less names for this; `npm run check` fails on a versioned one.
export const DMG_URL = 'https://github.com/ALIRAZA47/ladle-mac/releases/latest/download/Ladle.dmg';
/** The Chrome, Arc, Edge and Brave extension, loaded in developer mode until it's in the Chrome Web Store. */
export const CHROME_EXTENSION_ZIP_URL =
	'https://github.com/ALIRAZA47/ladle-mac/releases/latest/download/Ladle-Chrome-Extension.zip';
export const LATEST_RELEASE_URL = 'https://github.com/ALIRAZA47/ladle-mac/releases/latest';
export const RELEASES_URL = 'https://github.com/ALIRAZA47/ladle-mac/releases';
export const SOURCE_URL = 'https://github.com/ALIRAZA47/ladle-mac';
/** Installs Ladle and sets up its Chrome extension from Terminal. The script is public/install.sh. */
export const INSTALL_COMMAND = `curl -fsSL ${SITE_URL}/install.sh | bash`;
export const INSTALL_SCRIPT_SOURCE = 'https://github.com/ALIRAZA47/ladle-mac/blob/main/site/public/install.sh';
export const SUPPORT_URL = 'https://github.com/ALIRAZA47/ladle-mac/issues';
export const APPCAST_URL = `${SITE_URL}/appcast.xml`;

/** Used when neither the appcast nor the changelog names a version. */
export const FALLBACK_VERSION = '0.1.1';

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
