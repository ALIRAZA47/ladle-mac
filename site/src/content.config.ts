import { defineCollection } from 'astro:content';
import { glob } from 'astro/loaders';
import { z } from 'astro/zod';
import { docsLoader, i18nLoader } from '@astrojs/starlight/loaders';
import { docsSchema, i18nSchema } from '@astrojs/starlight/schema';

export const collections = {
	docs: defineCollection({ loader: docsLoader(), schema: docsSchema() }),
	i18n: defineCollection({ loader: i18nLoader(), schema: i18nSchema() }),
	/** One Markdown file per release, named after its version, e.g. `1.0.0.md`. */
	changelog: defineCollection({
		loader: glob({ base: './src/content/changelog', pattern: '*.md' }),
		schema: z.object({
			version: z.string().regex(/^\d+\.\d+\.\d+$/, 'Use a plain version number like 1.2.0'),
			title: z.string(),
			/** Release day. The app's release workflow fills it in when it publishes the release. */
			date: z.coerce.date().optional(),
		}),
	}),
};
