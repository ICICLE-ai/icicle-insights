<script lang="ts">
	import * as ToggleGroup from '$lib/components/ui/toggle-group';
	import { RANGES, rangeID, setParams } from '$lib/scope.svelte';

	/** The date range, first in the filter row because it is the filter everyone reaches for. */
	const short: Record<string, string> = { '30d': '30d', '90d': '90d', '6m': '6m', '1y': '1y' };
</script>

<ToggleGroup.Root
	type="single"
	variant="outline"
	size="sm"
	value={rangeID()}
	onValueChange={(value) => value && setParams({ range: value })}
	aria-label="Date range"
>
	{#each RANGES as range (range.id)}
		<ToggleGroup.Item value={range.id} aria-label="Last {range.label}" class="px-2.5 text-xs"
			>{short[range.id]}</ToggleGroup.Item
		>
	{/each}
</ToggleGroup.Root>
