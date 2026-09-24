<script lang="ts">
	import Delta from './delta.svelte';
	import Sparkline from './sparkline.svelte';
	import type { Tile } from '$lib/data/types';
	import { compact, metricLabel, whole } from '$lib/format';

	/**
	 * One metric's standing: the value, its change over the range, and a sparkline.
	 *
	 * A button when `onselect` is given, because on the overview a tile is also how you choose what
	 * the main chart plots — and a control has to be reachable from the keyboard like one.
	 */
	let {
		tile,
		selected = false,
		onselect
	}: { tile: Tile; selected?: boolean; onselect?: () => void } = $props();

	const label = $derived(metricLabel(tile.type));
</script>

{#snippet body()}
	<span class="truncate text-xs text-muted-foreground">{label}</span>
	<span class="flex items-baseline gap-2">
		<span class="text-2xl font-semibold tracking-tight" title={whole(tile.current)}
			>{compact(tile.current)}</span
		>
		<Delta current={tile.current} start={tile.atStart} mode="percent" />
	</span>
	{#if tile.series.length > 1}
		<Sparkline points={tile.series} width={140} height={26} label="{label} trend" />
	{:else if tile.kind === 'lifetime'}
		<span class="text-[11px] leading-[26px] text-muted-foreground">Lifetime total</span>
	{:else}
		<span class="text-[11px] leading-[26px] text-muted-foreground">One reading so far</span>
	{/if}
{/snippet}

{#if onselect}
	<button
		type="button"
		onclick={onselect}
		aria-pressed={selected}
		class="flex min-w-0 cursor-pointer flex-col gap-1 rounded-xl border bg-card p-3 text-left transition-colors outline-none hover:border-ring/60 focus-visible:ring-3 focus-visible:ring-ring/50
			{selected ? 'border-foreground/60 ring-2 ring-foreground/10' : ''}"
	>
		{@render body()}
	</button>
{:else}
	<div class="flex min-w-0 flex-col gap-1 rounded-xl border bg-card p-3">
		{@render body()}
	</div>
{/if}
