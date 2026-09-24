<script lang="ts">
	import { page } from '$app/state';
	import { ArrowLeft, ExternalLink } from '@lucide/svelte';
	import * as Card from '$lib/components/ui/card';
	import { Badge } from '$lib/components/ui/badge';
	import { Skeleton } from '$lib/components/ui/skeleton';
	import LoadError from '$lib/components/load-error.svelte';
	import PlatformDot from '$lib/components/platform-dot.svelte';
	import StatTile from '$lib/components/stat-tile.svelte';
	import TrendChart from '$lib/components/trend-chart.svelte';
	import { loadCatalog } from '$lib/data/catalog';
	import { buildProvenance } from '$lib/data/provenance';
	import { source } from '$lib/data/source';
	import {
		compact,
		formatDate,
		formatRelative,
		kindLabel,
		METRICS,
		metricLabel,
		platformColor,
		pluralize
	} from '$lib/format';
	import { platformURL } from '$lib/links';
	import { query } from '$lib/query.svelte';
	import { bucketFor, rangeLabel, scope, withScope } from '$lib/scope.svelte';

	/**
	 * One resource: its numbers, a small chart per metric, its releases, and the other registries
	 * Patra says it is also published under.
	 *
	 * Small multiples rather than one chart with every metric: stars and views differ by orders of
	 * magnitude, and a shared y-axis would flatten the smaller ones into the floor.
	 */
	const id = $derived(page.params.id!.toLowerCase());

	const data = query(async () => {
		const resourceID = id;
		const current = scope(resourceID);
		const [src, catalog] = await Promise.all([source(), loadCatalog()]);
		const resource = catalog.resourceByID.get(resourceID);
		if (!resource) return { missing: true as const };
		const summary = await src.summary(current);
		const trending = summary.tiles.filter((tile) => tile.kind !== 'lifetime');
		const series = await Promise.all(
			trending.map((tile) => src.series(current, tile.type, 'none', bucketFor(current)))
		);
		return { missing: false as const, catalog, resource, summary, trending, series };
	});

	const view = $derived.by(() => {
		const d = data.data;
		if (!d || d.missing) return null;
		const platform = d.catalog.platformOf.get(id) ?? null;
		const account = d.catalog.accountByID.get(d.resource.accountID?.toLowerCase() ?? '') ?? null;
		const releases = d.catalog.releases
			.filter((release) => release.resourceID?.toLowerCase() === id)
			.sort((a, b) => (b.releasedAt ?? '').localeCompare(a.releasedAt ?? ''));
		// Every other row in this artifact's provenance group, not only the direct links: the GitHub
		// repository's Patra card also names the Hugging Face dataset, and that is the same artifact.
		const cluster = buildProvenance(d.catalog.resources, d.catalog.platformOf).clusters.find(
			(c) => c.hub.id === id || c.others.some((o) => o.id === id)
		);
		const linked = cluster ? [cluster.hub, ...cluster.others].filter((n) => n.id !== id) : [];
		return {
			platform,
			account,
			releases,
			linked,
			external: platformURL(
				platform,
				account?.name ?? null,
				d.resource.name ?? '',
				d.resource.type ?? 'repository'
			),
			lifetime: d.summary.tiles.filter((tile) => tile.kind === 'lifetime')
		};
	});
</script>

<svelte:head
	><title
		>{data.data && !data.data.missing ? data.data.resource.name : 'Resource'} · ICICLE Insights</title
	></svelte:head
>

<div class="flex flex-col gap-6">
	<a
		href={withScope('/resources', ['range'])}
		class="inline-flex w-fit items-center gap-1 text-sm text-muted-foreground hover:text-foreground"
	>
		<ArrowLeft class="size-3.5" /> All resources
	</a>

	{#if data.error && !data.data}
		<LoadError error={data.error} retry={data.refresh} />
	{:else if !data.data}
		<Skeleton class="h-12 w-72" />
		<Skeleton class="h-64 rounded-xl" />
	{:else if data.data.missing}
		<div class="rounded-xl border bg-card p-10 text-center">
			<p class="font-medium">No resource with this ID.</p>
			<p class="text-sm text-muted-foreground">
				It may have been deleted, or the link is mistyped.
			</p>
		</div>
	{:else if view}
		{@const d = data.data}
		<div class="flex flex-wrap items-start justify-between gap-4">
			<div class="min-w-0">
				<h1 class="truncate text-2xl font-semibold tracking-tight">{d.resource.name}</h1>
				<div class="mt-1 flex flex-wrap items-center gap-x-3 gap-y-1 text-sm text-muted-foreground">
					<PlatformDot platform={view.platform} />
					<Badge variant="secondary">{kindLabel(d.resource.type)}</Badge>
					{#if view.account}<span>{view.account.name}</span>{/if}
					{#if view.external}
						<a
							href={view.external}
							target="_blank"
							rel="noopener noreferrer"
							class="inline-flex items-center gap-1 hover:text-foreground"
						>
							Open on platform <ExternalLink class="size-3" />
						</a>
					{/if}
				</div>
			</div>
			<dl class="grid grid-cols-[auto_auto] gap-x-3 gap-y-0.5 text-xs text-muted-foreground">
				<dt>Collected every</dt>
				<dd class="text-foreground">{pluralize(d.resource.collectionIntervalDays ?? 7, 'day')}</dd>
				<dt>Next collection</dt>
				<dd class="text-foreground">{formatRelative(d.resource.nextCollectionAt)}</dd>
				<dt>Tracked since</dt>
				<dd class="text-foreground">{formatDate(d.resource.createdAt)}</dd>
			</dl>
		</div>

		{#if d.resource.card}
			{@const card = d.resource.card}
			<section aria-labelledby="about-heading" class="rounded-xl border bg-card p-5">
				<h2 id="about-heading" class="text-sm font-medium">
					About this {card.kind === 'model' ? 'model' : 'dataset'}
				</h2>
				{#if card.description}<p class="mt-2 max-w-3xl text-sm text-muted-foreground">
						{card.description}
					</p>{/if}
				<dl class="mt-4 grid grid-cols-2 gap-x-6 gap-y-3 text-sm sm:grid-cols-3 lg:grid-cols-4">
					{#each [['Author', card.author], ['Category', card.category], ['Framework', card.framework], ['Model type', card.modelType], ['Input', card.inputType], ['Licence', card.license], ['Version', card.version], ['Test accuracy', card.accuracy != null ? `${(card.accuracy * 100).toFixed(1)}%` : null], ['Size', card.size], ['Format', card.format], ['Published', card.publicationYear ? String(card.publicationYear) : null], ['Card updated', card.updatedAt ? formatDate(card.updatedAt) : null]].filter(([, value]) => value) as [label, value] (label)}
						<div>
							<dt class="text-xs text-muted-foreground">{label}</dt>
							<dd>{value}</dd>
						</div>
					{/each}
				</dl>
				{#if card.keywords?.length}
					<ul class="mt-4 flex flex-wrap gap-1.5" aria-label="Keywords">
						{#each card.keywords as keyword (keyword)}
							<li class="rounded-full border px-2 py-0.5 text-[11px] text-muted-foreground">
								{keyword}
							</li>
						{/each}
					</ul>
				{/if}
				{#if card.sourceURL}
					<a
						href={card.sourceURL}
						target="_blank"
						rel="noopener noreferrer"
						class="mt-4 inline-flex items-center gap-1 text-xs text-muted-foreground hover:text-foreground"
					>
						Source recorded in Patra <ExternalLink class="size-3" />
					</a>
				{/if}
			</section>
		{/if}

		<div
			class={data.loading
				? 'flex flex-col gap-6 opacity-60 transition-opacity'
				: 'flex flex-col gap-6 transition-opacity'}
		>
			{#if d.trending.length}
				<section aria-label="Metrics" class="grid grid-cols-2 gap-3 md:grid-cols-3 xl:grid-cols-4">
					{#each d.trending as tile (tile.type)}<StatTile {tile} />{/each}
				</section>
			{:else if view.lifetime.length === 0}
				<div class="rounded-xl border bg-card p-8 text-center text-sm text-muted-foreground">
					No readings yet. {view.platform === 'ghcr' ||
					view.platform === 'npm' ||
					view.platform === 'pypi'
						? 'This platform has no collector yet.'
						: 'The first collection will fill this in.'}
				</div>
			{/if}

			{#if view.lifetime.length}
				<section
					aria-label="Lifetime totals"
					class="flex flex-wrap items-baseline gap-x-6 gap-y-2 text-sm"
				>
					<span class="text-xs font-medium tracking-wide text-muted-foreground uppercase"
						>Lifetime</span
					>
					{#each view.lifetime as tile (tile.type)}
						<span class="flex items-baseline gap-1.5"
							><span class="font-semibold">{compact(tile.current)}</span><span
								class="text-muted-foreground">{METRICS[tile.type].short.toLowerCase()}</span
							></span
						>
					{/each}
				</section>
			{/if}

			{#if d.series.length}
				<div class="grid gap-6 lg:grid-cols-2">
					{#each d.series as series (series.type)}
						<Card.Root>
							<Card.Header>
								<Card.Title class="text-sm">{metricLabel(series.type)}</Card.Title>
							</Card.Header>
							<Card.Content>
								<TrendChart
									height={200}
									label="{metricLabel(series.type)} for {d.resource.name}, last {rangeLabel()}"
									series={series.groups.map((group) => ({
										key: group.key,
										label: metricLabel(series.type),
										color: platformColor(view.platform),
										points: group.points
									}))}
								/>
							</Card.Content>
						</Card.Root>
					{/each}
				</div>
			{/if}

			<div class="grid gap-6 lg:grid-cols-2">
				<Card.Root>
					<Card.Header>
						<Card.Title class="text-sm">Releases</Card.Title>
						<Card.Description
							>{view.releases.length
								? pluralize(view.releases.length, 'release')
								: 'None recorded'}</Card.Description
						>
					</Card.Header>
					{#if view.releases.length}
						<Card.Content>
							<ul class="divide-y text-sm">
								{#each view.releases.slice(0, 12) as release (release.id)}
									<li class="flex items-center justify-between py-1.5">
										<span class="font-mono text-xs">{release.version}</span>
										<span class="text-xs text-muted-foreground"
											>{formatDate(release.releasedAt)}</span
										>
									</li>
								{/each}
							</ul>
						</Card.Content>
					{/if}
				</Card.Root>

				<Card.Root>
					<Card.Header>
						<Card.Title class="text-sm">Also registered as</Card.Title>
						<Card.Description>
							{view.linked.length
								? 'The same artifact on other registries, as recorded by Patra'
								: 'No other registries recorded by Patra'}
						</Card.Description>
					</Card.Header>
					{#if view.linked.length}
						<Card.Content>
							<ul class="flex flex-col gap-2 text-sm">
								{#each view.linked as link (link.id)}
									<li class="flex items-center justify-between gap-3">
										<a
											href={withScope(`/resources/${link.id}`, ['range'])}
											class="truncate font-medium hover:underline">{link.name}</a
										>
										<PlatformDot platform={link.platform} />
									</li>
								{/each}
							</ul>
						</Card.Content>
					{/if}
				</Card.Root>
			</div>
		</div>
	{/if}
</div>
