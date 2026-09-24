<script lang="ts">
	import './layout.css';
	import { onMount } from 'svelte';
	import { ModeWatcher } from 'mode-watcher';
	import { Toaster } from '$lib/components/ui/sonner';
	import * as Tooltip from '$lib/components/ui/tooltip';
	import AppHeader from '$lib/components/app-header.svelte';
	import { auth } from '$lib/auth.svelte';
	import { loadCatalog, type Catalog } from '$lib/data/catalog';

	let { children } = $props();

	let catalog = $state<Catalog | null>(null);

	onMount(() => {
		auth.initialize();
		loadCatalog()
			.then((loaded) => (catalog = loaded))
			// Each page reports its own load failure where the content would be; the header's
			// picker simply stays empty rather than showing a second copy of the same error.
			.catch(() => {});
	});
</script>

<ModeWatcher />
<Toaster richColors position="bottom-right" />
<Tooltip.Provider delayDuration={200}>
	<div class="flex min-h-dvh flex-col">
		<AppHeader {catalog} />
		<main class="mx-auto w-full max-w-7xl flex-1 px-4 py-6 sm:px-6">
			{@render children()}
		</main>
		<footer class="border-t text-muted-foreground">
			<div
				class="mx-auto grid max-w-7xl gap-6 px-4 py-6 text-xs leading-relaxed sm:grid-cols-2 sm:px-6"
			>
				<p>
					<span class="font-medium text-foreground">About these figures.</span>
					Each number is a reading taken on the resource's own collection schedule, usually weekly, not
					a live counter. Windowed metrics say which window they cover; totals add up each resource's
					newest reading.
				</p>
				<p>
					<span class="font-medium text-foreground">Acknowledgment.</span>
					National Science Foundation (NSF) funded AI institute for Intelligent Cyberinfrastructure with
					Computational Learning in the Environment (ICICLE) (OAC 2112606).
				</p>
			</div>
		</footer>
	</div>
</Tooltip.Provider>
