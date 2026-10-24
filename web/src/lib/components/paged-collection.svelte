<script lang="ts" generics="T">
	import { tick, type Snippet } from 'svelte';
	import { ChevronLeft, ChevronRight } from '@lucide/svelte';
	import { Button } from '$lib/components/ui/button';
	import { whole } from '$lib/format';

	let {
		items,
		label,
		pageSize = 12,
		children
	}: { items: T[]; label: string; pageSize?: number; children: Snippet<[T[]]> } = $props();

	let page = $state(0);
	let region: HTMLElement;
	const size = $derived(Math.max(1, Math.floor(pageSize)));
	const pages = $derived(Math.max(1, Math.ceil(items.length / size)));
	const current = $derived(Math.min(page, pages - 1));
	const start = $derived(current * size);

	// A filter, sort, or scope change starts at the first result, including when its count is unchanged.
	$effect(() => {
		void items;
		page = 0;
	});

	async function changePage(next: number) {
		page = next;
		await tick();
		region.focus({ preventScroll: true });
		region.scrollIntoView({ block: 'start' });
	}
</script>

<section
	bind:this={region}
	aria-label={label}
	tabindex="-1"
	class="flex min-w-0 scroll-mt-40 flex-col gap-4 outline-none"
>
	{@render children(items.slice(start, start + size))}
	{#if pages > 1}
		<nav aria-label="{label} pages" class="flex flex-wrap items-center justify-end gap-2 text-xs">
			<span class="text-muted-foreground" aria-live="polite">
				{whole(start + 1)}–{whole(Math.min(start + size, items.length))} of {whole(items.length)}
				· Page {current + 1} of {pages}
			</span>
			<Button
				variant="outline"
				size="icon-sm"
				disabled={current === 0}
				onclick={() => changePage(current - 1)}
				aria-label="Previous {label.toLowerCase()} page"><ChevronLeft /></Button
			>
			<Button
				variant="outline"
				size="icon-sm"
				disabled={current === pages - 1}
				onclick={() => changePage(current + 1)}
				aria-label="Next {label.toLowerCase()} page"><ChevronRight /></Button
			>
		</nav>
	{/if}
</section>
