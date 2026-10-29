import { defineRouteMiddleware } from '@astrojs/starlight/route-data';
import { docsSections } from './config/docs-nav.mjs';

/** Extra per-page data the docs components read from `Astro.locals.ladle`. */
export interface LadleRouteData {
	/** The sidebar group this page belongs to, for the breadcrumb. */
	section?: { label: string; href: string };
	/** Rough reading time in minutes. */
	minutes: number;
}

declare global {
	namespace App {
		interface Locals {
			ladle?: LadleRouteData;
		}
	}
}

function readingMinutes(body: string | undefined): number {
	if (!body) return 1;
	const text = body
		.replace(/^---[\s\S]*?---/, ' ')
		.replace(/^import .*$/gm, ' ')
		.replace(/\{\/\*[\s\S]*?\*\/\}/g, ' ')
		.replace(/<[^>]+>/g, ' ')
		.replace(/[#*_`>|[\]()-]/g, ' ');
	const words = text.split(/\s+/).filter(Boolean).length;
	return Math.max(1, Math.round(words / 200));
}

export const onRequest = defineRouteMiddleware((context) => {
	const route = context.locals.starlightRoute;

	// The design's "On this page" lists the page's sections only, not the page title.
	if (route.toc) {
		route.toc.items = route.toc.items.filter((item) => item.slug !== '_top');
		if (route.toc.items.length === 0) route.toc = undefined;
	}

	const slug = route.entry.id;
	const section = docsSections.find((s) => s.pages.some((page) => page.slug === slug));
	context.locals.ladle = {
		section: section ? { label: section.label, href: `/docs/#${section.home}` } : undefined,
		minutes: readingMinutes(route.entry.body),
	};
});
