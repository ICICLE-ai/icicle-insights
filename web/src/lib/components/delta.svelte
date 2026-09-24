<script lang="ts">
	import { formatPercent, percentChange, signed } from '$lib/format';

	/**
	 * Change over the selected range, signed and coloured by direction.
	 *
	 * Every metric here is "more is better", so up is gain-green and down is loss-red. The sign is
	 * always written out, so the direction never rests on colour alone.
	 */
	let {
		current,
		start,
		mode = 'both'
	}: { current: number; start: number | null; mode?: 'both' | 'absolute' | 'percent' } = $props();

	const change = $derived(start === null ? null : current - start);
	const percent = $derived(percentChange(current, start));
</script>

{#if change !== null}
	<span
		class="numeric text-xs font-medium whitespace-nowrap {change > 0
			? 'text-gain'
			: change < 0
				? 'text-loss'
				: 'text-muted-foreground'}"
	>
		{#if mode !== 'percent'}{signed(change)}{/if}
		{#if mode !== 'absolute' && percent !== null}
			<span class={mode === 'both' ? 'font-normal text-muted-foreground' : ''}>
				{mode === 'both' ? `(${formatPercent(percent)})` : formatPercent(percent)}
			</span>
		{/if}
	</span>
{/if}
