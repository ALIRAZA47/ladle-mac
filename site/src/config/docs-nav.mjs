// The docs table of contents. It drives the Starlight sidebar (and so the previous/next links),
// the topic cards on the docs home, breadcrumbs and the section names shown in search results.
// Page titles come from each page's frontmatter.

/**
 * @typedef {{ slug: string }} DocsPage
 * @typedef {{ id: string, label: string, home: string, pages: DocsPage[] }} DocsSection
 */

/** @type {DocsSection[]} */
export const docsSections = [
	{
		id: 'getting-started',
		label: 'Getting started',
		home: 'getting-started',
		pages: [
			{ slug: 'docs/getting-started/install' },
			{ slug: 'docs/getting-started/set-up-your-browser' },
			{ slug: 'docs/getting-started/first-download' },
			{ slug: 'docs/getting-started/menu-bar-dock-and-notifications' },
		],
	},
	{
		id: 'adding-downloads',
		label: 'Adding downloads',
		home: 'adding-downloads',
		pages: [
			{ slug: 'docs/adding-downloads/paste-drop-or-shortcut' },
			{ slug: 'docs/adding-downloads/many-links' },
			{ slug: 'docs/adding-downloads/video-button' },
		],
	},
	{
		id: 'queues-and-speed',
		label: 'Queues and speed',
		home: 'queues-and-speed',
		pages: [
			{ slug: 'docs/queues-and-speed/main-queue' },
			{ slug: 'docs/queues-and-speed/tonight-queue' },
			{ slug: 'docs/queues-and-speed/connections-and-speed-limits' },
		],
	},
	{
		id: 'files-and-folders',
		label: 'Files and folders',
		home: 'files-and-folders',
		pages: [
			{ slug: 'docs/files-and-folders/categories-and-folders' },
			{ slug: 'docs/files-and-folders/duplicate-file-names' },
			{ slug: 'docs/files-and-folders/checksums' },
		],
	},
	{
		id: 'fixing-problems',
		label: 'Fixing problems',
		home: 'fixing-problems',
		pages: [
			{ slug: 'docs/fixing-problems/download-failed' },
			{ slug: 'docs/fixing-problems/wont-resume' },
			{ slug: 'docs/fixing-problems/browser-not-handing-off' },
		],
	},
	{
		id: 'updates',
		label: 'Updates',
		home: 'updates-and-reference',
		pages: [{ slug: 'docs/updates' }],
	},
	{
		id: 'reference',
		label: 'Reference',
		home: 'updates-and-reference',
		pages: [{ slug: 'docs/reference/keyboard-shortcuts' }, { slug: 'docs/reference/settings' }],
	},
];

/** Starlight sidebar config. */
export const sidebar = docsSections.map((section) => ({
	label: section.label,
	items: section.pages.map(({ slug }) => ({ slug })),
}));

/** The six "Browse by topic" cards on the docs home. Updates and Reference share one. */
export const topicCards = [
	{ id: 'getting-started', title: 'Getting started', icon: 'start', sections: ['getting-started'] },
	{ id: 'adding-downloads', title: 'Adding downloads', icon: 'link', sections: ['adding-downloads'] },
	{ id: 'queues-and-speed', title: 'Queues and speed', icon: 'bolt', sections: ['queues-and-speed'] },
	{ id: 'files-and-folders', title: 'Files and folders', icon: 'folder', sections: ['files-and-folders'] },
	{ id: 'fixing-problems', title: 'Fixing problems', icon: 'refresh', sections: ['fixing-problems'] },
	{ id: 'updates-and-reference', title: 'Updates and reference', icon: 'sliders', sections: ['updates', 'reference'] },
];

/** `/docs/x/y/` for a slug like `docs/x/y`. */
export const hrefFor = (slug) => `/${slug.replace(/^\/+|\/+$/g, '')}/`;

/** Section label for a docs URL path, used to label search results. */
export function sectionForPath(pathname) {
	for (const section of docsSections) {
		if (section.pages.some(({ slug }) => hrefFor(slug) === pathname)) return section;
	}
	return undefined;
}
