<script lang="ts">
	import type { Platform, Resource } from '$lib/api/types';
	import type { ResourceRow } from '$lib/data/types';
	import type { ProvenanceNode } from '$lib/data/provenance';
	import { compact, kindLabel, platformColor, platformLabel, whole } from '$lib/format';
	import { withScope } from '$lib/scope.svelte';

	/**
	 * One model or dataset as a card: what it is, who made it, how it's used, and where else it's
	 * published.
	 *
	 * The whole card is one link to the resource's page, with the title as the accessible name; the
	 * "also on" links sit above that layer so they stay separately clickable rather than nesting a
	 * link inside a link.
	 */
	let {
		resource,
		platform,
		row,
		elsewhere
	}: {
		resource: Resource;
		platform: Platform | null;
		row: ResourceRow | undefined;
		elsewhere: ProvenanceNode[];
	} = $props();

	const card = $derived(resource.card ?? null);
	const id = $derived(resource.id!.toLowerCase());

	const facts = $derived(
		[card?.category, card?.framework, card?.modelType, card?.format, card?.license]
			.map((value) => value?.trim())
			.filter(
				(value, i, all): value is string =>
					!!value && all.findIndex((v) => v?.toLowerCase() === value.toLowerCase()) === i
			)
	);

	// Usage figures in the order a reader weighs them, and only the ones this resource reports:
	// a Patra card has deployments, a Hub model downloads and likes.
	const usage = $derived(
		[
			{ label: 'deployments', value: row?.latest.deployments },
			{ label: 'downloads · 30 days', value: row?.latest.downloads },
			{ label: 'downloads all time', value: row?.latest.downloadsAllTime },
			{ label: 'likes', value: row?.latest.likes }
		].filter((item): item is { label: string; value: number } => item.value !== undefined)
	);
</script>

<article
	class="group relative flex h-full flex-col gap-3 rounded-xl border bg-card p-4 transition-colors hover:border-ring/60"
>
	<header class="flex items-start justify-between gap-3">
		<div class="min-w-0">
			<h3 class="leading-snug font-medium">
				<a
					href={withScope(`/resources/${id}`, ['range'])}
					class="outline-none after:absolute after:inset-0 after:rounded-xl focus-visible:after:ring-3 focus-visible:after:ring-ring/50"
				>
					{resource.name}
				</a>
			</h3>
			<p class="mt-0.5 flex flex-wrap items-center gap-x-2 text-xs text-muted-foreground">
				<span class="inline-flex items-center gap-1">
					<span
						class="inline-block size-2 rounded-full"
						style="background:{platformColor(platform)}"
						aria-hidden="true"
					></span>
					{platformLabel(platform)}
				</span>
				{#if card?.author}<span>by {card.author}</span>{/if}
				{#if card?.publicationYear}<span>{card.publicationYear}</span>{/if}
			</p>
		</div>
		{#if card?.version}
			<span
				class="shrink-0 rounded-md bg-muted px-1.5 py-0.5 font-mono text-[11px] text-muted-foreground"
				>{card.version}</span
			>
		{/if}
	</header>

	{#if card?.description}
		<p class="line-clamp-3 text-sm text-muted-foreground">{card.description}</p>
	{:else}
		<p class="text-sm text-muted-foreground/70 italic">
			{card
				? 'No description in Patra.'
				: `A ${kindLabel(resource.type).toLowerCase()} on ${platformLabel(platform)}.`}
		</p>
	{/if}

	{#if facts.length}
		<ul class="flex flex-wrap gap-1.5" aria-label="Details">
			{#each facts as fact (fact)}
				<li class="rounded-full border px-2 py-0.5 text-[11px] text-muted-foreground">{fact}</li>
			{/each}
		</ul>
	{/if}

	<footer class="mt-auto flex flex-col gap-2 border-t pt-3 text-xs">
		{#if usage.length || card?.accuracy != null || card?.size}
			<dl class="flex flex-wrap gap-x-4 gap-y-1">
				{#each usage as item (item.label)}
					<div class="flex items-baseline gap-1">
						<dt class="sr-only">{item.label}</dt>
						<dd class="font-semibold text-foreground" title={whole(item.value)}>
							{compact(item.value)}
						</dd>
						<dd class="text-muted-foreground" aria-hidden="true">{item.label}</dd>
					</div>
				{/each}
				{#if card?.accuracy != null}
					<div class="flex items-baseline gap-1">
						<dt class="sr-only">Test accuracy</dt>
						<dd class="font-semibold text-foreground">{(card.accuracy * 100).toFixed(1)}%</dd>
						<dd class="text-muted-foreground" aria-hidden="true">test accuracy</dd>
					</div>
				{/if}
				{#if card?.size}
					<div class="flex items-baseline gap-1">
						<dt class="sr-only">Size</dt>
						<dd class="text-muted-foreground">{card.size}</dd>
					</div>
				{/if}
			</dl>
		{:else}
			<p class="text-muted-foreground">No usage figures collected yet.</p>
		{/if}
		{#if elsewhere.length}
			<p class="relative z-10 flex flex-wrap items-center gap-x-3 gap-y-1 text-muted-foreground">
				<span>Also on</span>
				{#each elsewhere as node (node.id)}
					<a
						href={withScope(`/resources/${node.id}`, ['range'])}
						class="inline-flex items-center gap-1 hover:text-foreground hover:underline"
						title={node.name}
					>
						<span
							class="inline-block size-2 rounded-full"
							style="background:{platformColor(node.platform)}"
							aria-hidden="true"
						></span>
						{platformLabel(node.platform)}
					</a>
				{/each}
			</p>
		{/if}
	</footer>
</article>
