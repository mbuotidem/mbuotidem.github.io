import { defineConfig } from 'astro/config'
import mdx from '@astrojs/mdx'
import sitemap from '@astrojs/sitemap'
import tailwind from '@astrojs/tailwind'
import { remarkReadingTime } from './src/utils/readTime.ts'
import { defineConfig, squooshImageService } from 'astro/config';

// https://astro.build/config
export default defineConfig({
	image: {
		service: squooshImageService(),
	},
	site: 'https://mbuotidem.github.io/', // Write here your website url
	markdown: {
		remarkPlugins: [remarkReadingTime],
		drafts: true,
		shikiConfig: {
			theme: 'material-theme-palenight',
			wrap: true
		}
	},
	integrations: [
		mdx({
			syntaxHighlight: 'shiki',
			shikiConfig: {
				experimentalThemes: {
					light: 'github-light',
					dark: 'github-dark',
				},
				wrap: true
			},
			drafts: true
		}),
		sitemap(),
		tailwind()
	]
})
