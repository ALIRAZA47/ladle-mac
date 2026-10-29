// @ts-check
import { defineConfig } from 'astro/config';
import starlight from '@astrojs/starlight';
import { sidebar } from './src/config/docs-nav.mjs';
import { SITE_URL } from './src/config/site.mjs';

const override = (name) => `./src/components/docs/${name}.astro`;

export default defineConfig({
	site: SITE_URL,
	trailingSlash: 'always',
	build: { format: 'directory' },
	integrations: [
		starlight({
			title: 'Ladle Docs',
			description: 'Guides for Ladle, the free download manager for Mac.',
			titleDelimiter: '—',
			favicon: '/favicon.svg',
			lastUpdated: true,
			disable404Route: true,
			pagination: true,
			sidebar,
			customCss: ['./src/styles/starlight.css'],
			routeMiddleware: './src/routeData.ts',
			components: {
				Head: override('Head'),
				Header: override('Header'),
				SiteTitle: override('SiteTitle'),
				ThemeSelect: override('ThemeSelect'),
				MobileMenuFooter: override('MobileMenuFooter'),
				Hero: override('Hero'),
				PageTitle: override('PageTitle'),
				Footer: override('Footer'),
				Pagination: override('Pagination'),
			},
			head: [
				{ tag: 'link', attrs: { rel: 'icon', href: '/favicon.ico', sizes: '32x32' } },
				{ tag: 'link', attrs: { rel: 'apple-touch-icon', href: '/apple-touch-icon.png' } },
				{ tag: 'meta', attrs: { property: 'og:image', content: `${SITE_URL}/og.png` } },
				{ tag: 'meta', attrs: { property: 'og:image:width', content: '1200' } },
				{ tag: 'meta', attrs: { property: 'og:image:height', content: '630' } },
				{ tag: 'meta', attrs: { property: 'og:image:alt', content: 'Ladle — Downloads, poured fast.' } },
				{ tag: 'meta', attrs: { name: 'twitter:image', content: `${SITE_URL}/og.png` } },
			],
			expressiveCode: {
				themes: ['github-dark-default', 'github-light-default'],
				styleOverrides: {
					borderRadius: '1rem',
					borderColor: 'var(--ld-line)',
					codeFontSize: '0.875rem',
					frames: { shadowColor: 'transparent', editorActiveTabIndicatorTopColor: 'transparent' },
				},
			},
		}),
	],
});
