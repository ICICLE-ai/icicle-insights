<script lang="ts">
	import type { Snippet } from 'svelte';
	import { Label } from '$lib/components/ui/label';

	/** A form field: label, control, and a hint that says what the server will accept. */
	let {
		id,
		label,
		hint,
		children
	}: { id: string; label: string; hint?: string; children: Snippet } = $props();
</script>

<div class="flex flex-col gap-1.5">
	<Label for={id}>{label}</Label>
	{@render children()}
	{#if hint}<p id="{id}-hint" class="text-xs text-muted-foreground">{hint}</p>{/if}
</div>
