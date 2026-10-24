<script lang="ts">
	import TableViewport from '$lib/components/table-viewport.svelte';
	import { cn, type WithElementRef } from '$lib/utils.js';
	import type { HTMLTableAttributes } from 'svelte/elements';

	let {
		ref = $bindable(null),
		class: className,
		children,
		...restProps
	}: WithElementRef<HTMLTableAttributes> = $props();
</script>

<TableViewport
	label={restProps['aria-label'] ?? 'Data table'}
	data-slot="table-container"
	class="border-0"
>
	<table
		bind:this={ref}
		data-slot="table"
		class={cn('w-full caption-bottom text-sm', className)}
		{...restProps}
	>
		{@render children?.()}
	</table>
</TableViewport>
