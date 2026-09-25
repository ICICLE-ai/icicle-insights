<script lang="ts">
	import { page } from '$app/state';
	import { Search } from '@lucide/svelte';
	import { Input } from '$lib/components/ui/input';
	import * as Select from '$lib/components/ui/select';
	import * as ToggleGroup from '$lib/components/ui/toggle-group';
	import { Skeleton } from '$lib/components/ui/skeleton';
	import LoadError from '$lib/components/load-error.svelte';
	import ModelCard from '$lib/components/model-card.svelte';
	import { loadCatalog, scopedResourceIDs } from '$lib/data/catalog';
	import { buildProvenance } from '$lib/data/provenance';
	import { source } from '$lib/data/source';
	import { compact, platformLabel, pluralize } from '$lib/format';
	import { query } from '$lib/query.svelte';
	import { platformParam, scope, setParams } from '$lib/scope.svelte';

	/**
	 * The institute's models and datasets as a browsable gallery — the view people asked for by
	 * name, rather than rows in the resource table.
	 *
	 * A card per resource, not per Patra card: one model often has a card per version, and the
	 * gallery is about what exists, so each resource shows its newest card. The same artifact on
	 * several registries stays one card per row here, with "also on" pointing at the others, because
	 * each row carries its own usage figures.
	 */
	const data = query(async () => {
		const current = scope();
		const [catalog, page] = await Promise.all([
			loadCatalog(),
			source.resources(current, { sort: 'deployments', order: 'desc', limit: 500, offset: 0 })
		]);
		return {
			catalog,
			rows: new Map(page.rows.map((row) => [row.id.toLowerCase(), row])),
			ids: scopedResourceIDs(catalog, current),
			provenance: buildProvenance(catalog.resources, catalog.platformOf).clusters
		};
	});

	type Kind = 'model' | 'dataset';
	type Sort = 'deployed' | 'downloaded' | 'name' | 'updated';

	const kind = $derived<Kind>(
		page.url.searchParams.get('kind') === 'dataset' ? 'dataset' : 'model'
	);
	const sort = $derived<Sort>(
		(['downloaded', 'name', 'updated'] as const).find(
			(s) => s === page.url.searchParams.get('sort')
		) ?? 'deployed'
	);
	const category = $derived(page.url.searchParams.get('category'));
	let search = $state('');

	// Deployments (Patra) and downloads (the Hub) are different units, so they are separate orders
	// rather than one sum; each breaks its ties on the other.
	const SORTS: Record<Sort, string> = {
		deployed: 'Most deployed',
		downloaded: 'Most downloaded',
		name: 'Name',
		updated: 'Recently updated'
	};

	const all = $derived.by(() => {
		const d = data.data;
		if (!d) return [];
		return d.catalog.resources
			.filter(
				(r) => r.id && d.ids.has(r.id.toLowerCase()) && (r.type === 'model' || r.type === 'dataset')
			)
			.map((resource) => {
				const id = resource.id!.toLowerCase();
				const cluster = d.provenance.find(
					(c) => c.hub.id === id || c.others.some((o) => o.id === id)
				);
				return {
					resource,
					id,
					platform: d.catalog.platformOf.get(id) ?? null,
					row: d.rows.get(id),
					elsewhere: cluster ? [cluster.hub, ...cluster.others].filter((n) => n.id !== id) : []
				};
			});
	});

	const counts = $derived({
		model: all.filter((m) => m.resource.type === 'model').length,
		dataset: all.filter((m) => m.resource.type === 'dataset').length
	});

	// Patra's categories are free text ("Object Detection", "object detection", "detection"), so the
	// filter groups them case-insensitively and shows the most common spelling.
	const categories = $derived.by(() => {
		const groups = new Map<string, { label: string; count: number }>();
		for (const m of all) {
			const value = m.resource.type === kind ? m.resource.card?.category?.trim() : undefined;
			if (!value) continue;
			const key = value.toLowerCase();
			const group = groups.get(key) ?? { label: value, count: 0 };
			group.count++;
			groups.set(key, group);
		}
		return [...groups].sort((a, b) => b[1].count - a[1].count);
	});

	const deployed = (m: (typeof all)[number]) => m.row?.latest.deployments ?? 0;
	const downloaded = (m: (typeof all)[number]) =>
		m.row?.latest.downloadsAllTime ?? m.row?.latest.downloads ?? 0;

	const shown = $derived.by(() => {
		const needle = search.trim().toLowerCase();
		return all
			.filter((m) => m.resource.type === kind)
			.filter((m) => !category || m.resource.card?.category?.trim().toLowerCase() === category)
			.filter((m) => {
				if (!needle) return true;
				const c = m.resource.card;
				return [
					m.resource.name,
					c?.description,
					c?.author,
					c?.category,
					c?.framework,
					...(c?.keywords ?? [])
				].some((text) => text?.toLowerCase().includes(needle));
			})
			.sort((a, b) => {
				if (sort === 'name') return (a.resource.name ?? '').localeCompare(b.resource.name ?? '');
				if (sort === 'updated')
					return (b.resource.card?.updatedAt ?? '').localeCompare(a.resource.card?.updatedAt ?? '');
				const [first, second] =
					sort === 'downloaded' ? [downloaded, deployed] : [deployed, downloaded];
				return (
					first(b) - first(a) ||
					second(b) - second(a) ||
					(a.resource.name ?? '').localeCompare(b.resource.name ?? '')
				);
			});
	});

	const deployments = $derived(
		all
			.filter((m) => m.resource.type === kind)
			.reduce((sum, m) => sum + (m.row?.latest.deployments ?? 0), 0)
	);
	const downloads = $derived(
		all
			.filter((m) => m.resource.type === kind)
			.reduce((sum, m) => sum + (m.row?.latest.downloadsAllTime ?? 0), 0)
	);
	const described = $derived(all.some((m) => m.resource.card));
</script>

<svelte:head
	><title>{kind === 'model' ? 'Models' : 'Datasets'} · ICICLE Insights</title></svelte:head
>

<div class="flex flex-col gap-6">
	<div class="flex flex-wrap items-end justify-between gap-3">
		<div>
			<h1 class="text-xl font-semibold tracking-tight">
				{kind === 'model' ? 'Models' : 'Datasets'}
			</h1>
			<p class="text-sm text-muted-foreground">
				{#if data.data}
					{pluralize(
						kind === 'model' ? counts.model : counts.dataset,
						kind === 'model' ? 'model' : 'dataset'
					)}
					{platformParam() ? `on ${platformLabel(platformParam())}` : 'published by the institute'}
					{#if deployments}· {compact(deployments)} deployments{/if}
					{#if downloads}· {compact(downloads)} downloads all time{/if}
				{:else}&nbsp;{/if}
			</p>
		</div>
		<ToggleGroup.Root
			type="single"
			variant="outline"
			size="sm"
			value={kind}
			onValueChange={(value) =>
				value && setParams({ kind: value === 'model' ? null : value, category: null })}
			aria-label="Show models or datasets"
		>
			<ToggleGroup.Item value="model" class="px-3 text-xs"
				>Models {data.data ? `(${counts.model})` : ''}</ToggleGroup.Item
			>
			<ToggleGroup.Item value="dataset" class="px-3 text-xs"
				>Datasets {data.data ? `(${counts.dataset})` : ''}</ToggleGroup.Item
			>
		</ToggleGroup.Root>
	</div>

	{#if data.error && !data.data}
		<LoadError error={data.error} retry={data.refresh} />
	{:else if !data.data}
		<div class="grid gap-4 sm:grid-cols-2 xl:grid-cols-3">
			{#each Array(6) as _, i (i)}<Skeleton class="h-56 rounded-xl" />{/each}
		</div>
	{:else}
		<div class="flex flex-wrap items-center gap-2">
			<div class="relative w-full max-w-72">
				<Search
					class="pointer-events-none absolute top-1/2 left-2.5 size-3.5 -translate-y-1/2 text-muted-foreground"
				/>
				<Input
					bind:value={search}
					placeholder="Search names, descriptions, authors"
					aria-label="Search {kind === 'model' ? 'models' : 'datasets'}"
					class="h-8 pl-8"
				/>
			</div>
			{#if categories.length}
				<Select.Root
					type="single"
					value={category ?? 'all'}
					onValueChange={(value) => setParams({ category: value === 'all' ? null : value })}
				>
					<Select.Trigger size="sm" class="min-w-44" aria-label="Category">
						{category
							? (categories.find(([key]) => key === category)?.[1].label ?? category)
							: 'All categories'}
					</Select.Trigger>
					<Select.Content>
						<Select.Item value="all" label="All categories" />
						{#each categories as [key, group] (key)}
							<Select.Item value={key} label="{group.label} ({group.count})" />
						{/each}
					</Select.Content>
				</Select.Root>
			{/if}
			<Select.Root
				type="single"
				value={sort}
				onValueChange={(value) => setParams({ sort: value === 'deployed' ? null : value })}
			>
				<Select.Trigger size="sm" class="ml-auto min-w-40" aria-label="Sort"
					>{SORTS[sort]}</Select.Trigger
				>
				<Select.Content>
					{#each Object.entries(SORTS) as [value, label] (value)}<Select.Item
							{value}
							{label}
						/>{/each}
				</Select.Content>
			</Select.Root>
		</div>

		{#if !described && all.length}
			<p class="rounded-lg border bg-card px-4 py-2.5 text-xs text-muted-foreground">
				Descriptions, authors and licences appear here once the server stores Patra's card details.
				Names, usage and cross-registry links are shown now.
			</p>
		{/if}

		{#if shown.length}
			<div
				class="grid gap-4 sm:grid-cols-2 xl:grid-cols-3 {data.loading
					? 'opacity-60 transition-opacity'
					: 'transition-opacity'}"
			>
				{#each shown as m (m.id)}
					<ModelCard
						resource={m.resource}
						platform={m.platform}
						row={m.row}
						elsewhere={m.elsewhere}
					/>
				{/each}
			</div>
		{:else}
			<div class="rounded-xl border bg-card p-10 text-center text-sm text-muted-foreground">
				{search || category
					? 'Nothing matches.'
					: `No ${kind === 'model' ? 'models' : 'datasets'} in this scope.`}
			</div>
		{/if}
	{/if}
</div>
