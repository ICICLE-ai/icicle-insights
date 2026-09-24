<script lang="ts">
	import PlatformDot from './platform-dot.svelte';
	import type { Catalog } from '$lib/data/catalog';
	import { kindPlural, whole } from '$lib/format';

	/**
	 * What is being measured: resources by kind, and by platform.
	 *
	 * Bars rather than the old donut. Five categories with a 52-to-2 spread are a ranking, and
	 * lengths on a shared baseline compare where angles don't. One neutral ink for every bar — kind
	 * is not a series, and the blue slot already means GitHub everywhere else on the page.
	 */
	let { catalog, ids }: { catalog: Catalog; ids: Set<string> } = $props();

	const kinds = $derived.by(() => {
		const counts = new Map<string, number>();
		for (const id of ids) {
			const kind = catalog.resourceByID.get(id)?.type;
			if (kind) counts.set(kind, (counts.get(kind) ?? 0) + 1);
		}
		return [...counts].sort((a, b) => b[1] - a[1]);
	});

	const platforms = $derived.by(() => {
		const counts = new Map<string, number>();
		for (const id of ids) {
			const platform = catalog.platformOf.get(id);
			if (platform) counts.set(platform, (counts.get(platform) ?? 0) + 1);
		}
		return catalog.platforms.filter((p) => counts.has(p)).map((p) => [p, counts.get(p)!] as const);
	});

	const max = $derived(Math.max(1, ...kinds.map(([, count]) => count)));
</script>

<div class="flex flex-col gap-5">
	<ul class="flex flex-col gap-2.5" aria-label="Resources by kind">
		{#each kinds as [kind, count] (kind)}
			<li class="grid grid-cols-[6.5rem_1fr_2.5rem] items-center gap-3 text-sm">
				<span class="truncate">{kindPlural(kind)}</span>
				<span class="h-1.5 overflow-hidden rounded-full bg-muted" aria-hidden="true">
					<span
						class="block h-full rounded-full bg-foreground/55"
						style="width:{(count / max) * 100}%"
					></span>
				</span>
				<span class="numeric text-right text-muted-foreground">{whole(count)}</span>
			</li>
		{/each}
	</ul>
	<div class="border-t pt-4">
		<ul class="flex flex-col gap-2 text-sm" aria-label="Resources by platform">
			{#each platforms as [platform, count] (platform)}
				<li class="flex items-center justify-between">
					<PlatformDot {platform} />
					<span class="numeric text-muted-foreground">{whole(count)}</span>
				</li>
			{/each}
		</ul>
	</div>
</div>
