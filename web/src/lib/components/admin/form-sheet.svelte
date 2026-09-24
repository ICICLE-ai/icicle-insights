<script lang="ts">
	import type { Snippet } from 'svelte';
	import * as Sheet from '$lib/components/ui/sheet';
	import { Button } from '$lib/components/ui/button';
	import { ApiError } from '$lib/api/client';

	/**
	 * A create or edit form in a side sheet, so the table it changes stays in view behind it.
	 *
	 * The sheet owns submission state: it disables the submit button while the request runs, keeps
	 * the form open with the server's reason when the request fails, and closes only on success.
	 * `validate` runs first and returns a message to show instead of sending a request the server
	 * would refuse.
	 */
	let {
		open = $bindable(false),
		title,
		description,
		submitLabel,
		destructive = false,
		validate,
		onsubmit,
		children
	}: {
		open?: boolean;
		title: string;
		description?: string;
		submitLabel: string;
		destructive?: boolean;
		validate?: () => string | null;
		onsubmit: () => Promise<void>;
		children: Snippet;
	} = $props();

	let submitting = $state(false);
	let error = $state<string | null>(null);

	$effect(() => {
		if (open) error = null;
	});

	async function submit(event: SubmitEvent) {
		event.preventDefault();
		error = validate?.() ?? null;
		if (error) return;
		submitting = true;
		try {
			await onsubmit();
			open = false;
		} catch (e) {
			error =
				e instanceof ApiError
					? `${e.reason}${e.requestID ? ` (request ${e.requestID})` : ''}`
					: e instanceof Error
						? e.message
						: 'The request failed.';
		} finally {
			submitting = false;
		}
	}
</script>

<Sheet.Root bind:open>
	<Sheet.Content class="w-full sm:max-w-md">
		<form onsubmit={submit} class="flex h-full flex-col" novalidate>
			<Sheet.Header>
				<Sheet.Title>{title}</Sheet.Title>
				{#if description}<Sheet.Description>{description}</Sheet.Description>{/if}
			</Sheet.Header>
			<div class="flex flex-1 flex-col gap-4 overflow-y-auto px-4">
				{@render children()}
				{#if error}
					<p
						role="alert"
						class="rounded-lg border border-loss/30 bg-loss/5 px-3 py-2 text-sm text-loss"
					>
						{error}
					</p>
				{/if}
			</div>
			<Sheet.Footer class="flex-row justify-end gap-2">
				<Button variant="outline" type="button" onclick={() => (open = false)}>Cancel</Button>
				<Button
					type="submit"
					variant={destructive ? 'destructive' : 'default'}
					disabled={submitting}
				>
					{submitting ? 'Saving…' : submitLabel}
				</Button>
			</Sheet.Footer>
		</form>
	</Sheet.Content>
</Sheet.Root>
