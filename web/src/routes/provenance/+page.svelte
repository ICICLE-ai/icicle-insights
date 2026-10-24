<script lang="ts">
	import PagedCollection from '$lib/components/paged-collection.svelte';
	import TableViewport from '$lib/components/table-viewport.svelte';
	import * as Card from '$lib/components/ui/card';
	import { Skeleton } from '$lib/components/ui/skeleton';
	import LoadError from '$lib/components/load-error.svelte';
	import PlatformDot from '$lib/components/platform-dot.svelte';
	import { loadCatalog } from '$lib/data/catalog';
	import { buildProvenance, type ProvenanceNode } from '$lib/data/provenance';
	import { platformColor, platformLabel, pluralize } from '$lib/format';
	import { query } from '$lib/query.svelte';
	import { platformParam, withScope } from '$lib/scope.svelte';

	/**
	 * The same artifact on several registries, as Patra recorded it. One card per artifact.
	 *
	 * The platform filter keeps a card when any of its members is on that platform, so filtering to
	 * Hugging Face still shows which Patra datasheets describe the Hub datasets.
	 */
	const data = query(async () => {
		const platform = platformParam();
		const catalog = await loadCatalog();
		const graph = buildProvenance(catalog.resources, catalog.platformOf);
		const keep = (nodes: ProvenanceNode[]) =>
			!platform || nodes.some((n) => n.platform === platform);
		return {
			clusters: graph.clusters.filter((c) => keep([c.hub, ...c.others])),
			links: graph.links.filter((l) => keep([l.from, l.to]))
		};
	});

	const href = (node: ProvenanceNode) => withScope(`/resources/${node.id}`, ['range']);
</script>

<svelte:head><title>Provenance · ICICLE Insights</title></svelte:head>

<div class="flex flex-col gap-6">
	<div>
		<h1 class="text-xl font-semibold tracking-tight">Provenance</h1>
		<p class="max-w-2xl text-sm text-muted-foreground">
			Artifacts published on more than one registry. A Patra model card or datasheet names the
			GitHub repository or Hugging Face entry it describes; each card below is one artifact and
			every registry it appears on.
		</p>
	</div>

	{#if data.error && !data.data}
		<LoadError error={data.error} retry={data.refresh} />
	{:else if !data.data}
		<Skeleton class="h-48 rounded-xl" />
	{:else if data.data.clusters.length === 0}
		<div class="rounded-xl border bg-card p-10 text-center text-sm text-muted-foreground">
			No cross-registry links recorded{platformParam()
				? ` for ${platformLabel(platformParam())}`
				: ''}. Links appear when a Patra card's location names a repository or Hub entry this
			deployment tracks.
		</div>
	{:else}
		<p class="text-sm text-muted-foreground">
			{pluralize(data.data.clusters.length, 'artifact')} across {pluralize(
				data.data.links.length,
				'link'
			)}
		</p>
		<PagedCollection items={data.data.clusters} label="Artifacts">
			{#snippet children(visible)}
				<div class="grid gap-4 sm:grid-cols-2 xl:grid-cols-3">
					{#each visible as cluster (cluster.hub.id)}
						<Card.Root class="gap-3 py-4">
							<Card.Content class="flex flex-col gap-3 px-4">
								<a
									href={href(cluster.hub)}
									class="-mx-2 flex flex-col gap-1 rounded-lg border-l-[3px] px-3 py-1.5 hover:bg-muted/50"
									style="border-left-color:{platformColor(cluster.hub.platform)}"
								>
									<span class="leading-snug font-medium [overflow-wrap:anywhere]"
										>{cluster.hub.name}</span
									>
									<span class="text-xs text-muted-foreground"
										><PlatformDot platform={cluster.hub.platform} /></span
									>
								</a>
								<div class="text-[11px] font-medium tracking-wide text-muted-foreground uppercase">
									Also registered as
								</div>
								<ul
									aria-label="Other registry entries"
									class="flex max-h-48 flex-col gap-1.5 overflow-auto"
								>
									{#each cluster.others as other (other.id)}
										<li>
											<a
												href={href(other)}
												class="-mx-2 flex items-center justify-between gap-3 rounded-lg border-l-[3px] px-3 py-1 text-sm hover:bg-muted/50"
												style="border-left-color:{platformColor(other.platform)}"
											>
												<span class="truncate">{other.name}</span>
												<span class="shrink-0 text-xs text-muted-foreground"
													>{platformLabel(other.platform)}</span
												>
											</a>
										</li>
									{/each}
								</ul>
							</Card.Content>
						</Card.Root>
					{/each}
				</div>
			{/snippet}
		</PagedCollection>

		<details class="text-sm">
			<summary class="cursor-pointer text-xs text-muted-foreground hover:text-foreground"
				>Show every link as a table</summary
			>
			<TableViewport label="Every recorded cross-registry link" class="mt-2">
				<table class="w-full text-sm">
					<caption class="sr-only">Every recorded cross-registry link</caption>
					<thead class="bg-muted text-xs text-muted-foreground">
						<tr
							><th scope="col" class="px-3 py-2 text-left font-medium">Recorded by</th><th
								scope="col"
								class="px-3 py-2 text-left font-medium">Names</th
							></tr
						>
					</thead>
					<tbody>
						{#each data.data.links as link (`${link.from.id}-${link.to.id}`)}
							<tr class="border-t">
								<td class="max-w-64 px-3 py-1.5 [overflow-wrap:anywhere]"
									>{link.from.name}
									<span class="text-muted-foreground">({platformLabel(link.from.platform)})</span
									></td
								>
								<td class="max-w-64 px-3 py-1.5 [overflow-wrap:anywhere]"
									>{link.to.name}
									<span class="text-muted-foreground">({platformLabel(link.to.platform)})</span></td
								>
							</tr>
						{/each}
					</tbody>
				</table>
			</TableViewport>
		</details>
	{/if}
</div>
