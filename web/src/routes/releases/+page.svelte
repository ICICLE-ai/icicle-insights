<script lang="ts">
	import { Search } from '@lucide/svelte';
	import * as Card from '$lib/components/ui/card';
	import { Input } from '$lib/components/ui/input';
	import { Skeleton } from '$lib/components/ui/skeleton';
	import ColumnChart from '$lib/components/column-chart.svelte';
	import LoadError from '$lib/components/load-error.svelte';
	import PlatformDot from '$lib/components/platform-dot.svelte';
	import { loadCatalog, scopedResourceIDs } from '$lib/data/catalog';
	import { formatDate, formatRelative, platformLabel, pluralize } from '$lib/format';
	import { query } from '$lib/query.svelte';
	import { platformParam, scope, withScope } from '$lib/scope.svelte';

	/**
	 * Release activity: how often the institute ships, and what shipped most recently.
	 *
	 * Months on the chart, not the page's date range. Releases are sparse, so a 30-day window is
	 * usually empty; the last 12 months show cadence. The range still filters the table.
	 */
	const data = query(async () => {
		const current = scope();
		const catalog = await loadCatalog();
		const ids = scopedResourceIDs(catalog, current);
		const releases = catalog.releases
			.filter((release) => release.releasedAt && ids.has(release.resourceID?.toLowerCase() ?? ''))
			.map((release) => {
				const id = release.resourceID!.toLowerCase();
				return {
					id: release.id ?? `${id}-${release.version}`,
					version: release.version ?? '—',
					releasedAt: release.releasedAt!,
					resourceID: id,
					resource: catalog.resourceByID.get(id)?.name ?? 'Unknown',
					platform: catalog.platformOf.get(id) ?? null
				};
			})
			.sort((a, b) => b.releasedAt.localeCompare(a.releasedAt));
		return { releases, from: current.from };
	});

	let filter = $state('');

	const months = $derived.by(() => {
		const now = new Date();
		const buckets = Array.from({ length: 12 }, (_, i) => {
			const d = new Date(Date.UTC(now.getUTCFullYear(), now.getUTCMonth() - 11 + i, 1));
			return {
				key: d.toISOString().slice(0, 7),
				label: d.toLocaleString('en-US', { month: 'short', timeZone: 'UTC' }),
				value: 0
			};
		});
		for (const release of data.data?.releases ?? []) {
			const bucket = buckets.find((b) => b.key === release.releasedAt.slice(0, 7));
			if (bucket) bucket.value++;
		}
		return buckets;
	});

	const inRange = $derived(
		(data.data?.releases ?? []).filter((r) => r.releasedAt.slice(0, 10) >= (data.data?.from ?? ''))
	);
	const shown = $derived(
		inRange.filter(
			(r) => !filter || `${r.resource} ${r.version}`.toLowerCase().includes(filter.toLowerCase())
		)
	);
</script>

<svelte:head><title>Releases · ICICLE Insights</title></svelte:head>

<div class="flex flex-col gap-6">
	<div>
		<h1 class="text-xl font-semibold tracking-tight">Releases</h1>
		<p class="text-sm text-muted-foreground">
			Published versions {platformParam()
				? `on ${platformLabel(platformParam())}`
				: 'across every platform'}.
		</p>
	</div>

	{#if data.error && !data.data}
		<LoadError error={data.error} retry={data.refresh} />
	{:else if !data.data}
		<Skeleton class="h-64 rounded-xl" />
	{:else}
		<Card.Root>
			<Card.Header>
				<Card.Title>Releases per month</Card.Title>
				<Card.Description
					>Last 12 months · {pluralize(
						months.reduce((sum, m) => sum + m.value, 0),
						'release'
					)}</Card.Description
				>
			</Card.Header>
			<Card.Content>
				<!-- Neutral ink: releases span every platform, and the blue slot means GitHub everywhere else. -->
				<ColumnChart
					data={months}
					unit="releases"
					label="Releases per month over the last 12 months"
					color="color-mix(in oklch, var(--foreground) 65%, transparent)"
				/>
			</Card.Content>
		</Card.Root>

		<Card.Root>
			<Card.Header>
				<Card.Title>Recent releases</Card.Title>
				<Card.Description
					>{pluralize(inRange.length, 'release')} since {formatDate(
						data.data.from
					)}</Card.Description
				>
			</Card.Header>
			<Card.Content class="flex flex-col gap-3">
				<div class="relative w-full max-w-64">
					<Search
						class="pointer-events-none absolute top-1/2 left-2.5 size-3.5 -translate-y-1/2 text-muted-foreground"
					/>
					<Input
						bind:value={filter}
						placeholder="Filter by resource or version"
						aria-label="Filter releases"
						class="h-8 pl-8 text-sm"
					/>
				</div>
				<div class="overflow-x-auto rounded-lg border">
					<table class="w-full min-w-[560px] text-sm">
						<caption class="sr-only">Releases in the selected range, newest first</caption>
						<thead class="bg-muted/50 text-xs text-muted-foreground">
							<tr>
								<th scope="col" class="px-3 py-2 text-left font-medium">Resource</th>
								<th scope="col" class="px-3 py-2 text-left font-medium">Version</th>
								<th scope="col" class="px-3 py-2 text-left font-medium">Platform</th>
								<th scope="col" class="px-3 py-2 text-right font-medium">Released</th>
							</tr>
						</thead>
						<tbody>
							{#each shown.slice(0, 100) as release (release.id)}
								<tr class="border-t hover:bg-muted/40">
									<td class="px-3 py-2"
										><a
											href={withScope(`/resources/${release.resourceID}`, ['range'])}
											class="font-medium hover:underline">{release.resource}</a
										></td
									>
									<td class="px-3 py-2 font-mono text-xs">{release.version}</td>
									<td class="px-3 py-2"><PlatformDot platform={release.platform} /></td>
									<td
										class="px-3 py-2 text-right text-xs whitespace-nowrap text-muted-foreground"
										title={formatDate(release.releasedAt)}>{formatRelative(release.releasedAt)}</td
									>
								</tr>
							{:else}
								<tr
									><td colspan="4" class="px-3 py-8 text-center text-muted-foreground"
										>No releases in this range.</td
									></tr
								>
							{/each}
						</tbody>
					</table>
				</div>
			</Card.Content>
		</Card.Root>
	{/if}
</div>
