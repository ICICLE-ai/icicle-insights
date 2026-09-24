import tailwindcss from '@tailwindcss/vite';
import { defineConfig } from 'vitest/config';
import adapter from '@sveltejs/adapter-static';
import { sveltekit } from '@sveltejs/kit/vite';

// The local Insights API (`just run`). Everything the browser asks the dev server for under these
// paths is forwarded there, so the app uses same-origin URLs in development exactly as it does
// when Vapor serves the built files in production.
const api = process.env.INSIGHTS_API ?? 'http://127.0.0.1:8080';

export default defineConfig({
	plugins: [
		tailwindcss(),
		sveltekit({
			compilerOptions: {
				// Force runes mode for the project, except for libraries. Can be removed in svelte 6.
				runes: ({ filename }) =>
					filename.split(/[/\\]/).includes('node_modules') ? undefined : true
			},
			// A single-page app: Vapor serves `index.html` for every unknown non-asset path (see
			// SPAController), so the fallback page is the whole app and nothing is prerendered.
			adapter: adapter({ pages: 'build', assets: 'build', fallback: 'index.html', strict: true })
		})
	],
	server: {
		// 5173 is Vite's default and is often taken by another project on the same machine.
		port: 5174,
		strictPort: true,
		proxy: {
			'/api': api,
			'/openapi.json': api
		}
	},
	test: {
		expect: { requireAssertions: true },
		projects: [
			{
				extends: './vite.config.ts',
				test: {
					name: 'unit',
					environment: 'node',
					include: ['src/**/*.{test,spec}.{js,ts}'],
					exclude: ['src/**/*.svelte.{test,spec}.{js,ts}']
				}
			}
		]
	}
});
