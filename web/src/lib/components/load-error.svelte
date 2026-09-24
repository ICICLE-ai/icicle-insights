<script lang="ts">
	import { CircleAlert } from '@lucide/svelte';
	import { Button } from '$lib/components/ui/button';
	import { ApiError } from '$lib/api/client';

	/** Where content would be: what went wrong, the request ID to quote, and a way to retry. */
	let { error, retry }: { error: unknown; retry?: () => void } = $props();

	const message = $derived(
		error instanceof ApiError
			? error.reason
			: error instanceof Error
				? error.message
				: 'Something went wrong loading this.'
	);
</script>

<div
	role="alert"
	class="flex flex-col items-start gap-3 rounded-xl border bg-card p-5 text-sm sm:flex-row sm:items-center"
>
	<CircleAlert class="size-5 shrink-0 text-loss" />
	<div class="flex-1">
		<p class="font-medium">Couldn't load this data.</p>
		<p class="text-muted-foreground">
			{message}
			{#if error instanceof ApiError && error.requestID}
				<span class="block text-xs"
					>Request ID <code class="font-mono">{error.requestID}</code></span
				>
			{/if}
		</p>
	</div>
	{#if retry}<Button variant="outline" size="sm" onclick={retry}>Try again</Button>{/if}
</div>
