<script lang="ts">
	import * as AlertDialog from '$lib/components/ui/alert-dialog';
	import { buttonVariants } from '$lib/components/ui/button';
	import { ApiError } from '$lib/api/client';

	/**
	 * Asks before an irreversible action, names exactly what will happen, and stays open with the
	 * server's reason if the action fails rather than closing as though it had worked.
	 */
	let {
		open = $bindable(false),
		title,
		description,
		confirmLabel,
		onconfirm
	}: {
		open?: boolean;
		title: string;
		description: string;
		confirmLabel: string;
		onconfirm: () => Promise<void>;
	} = $props();

	let busy = $state(false);
	let error = $state<string | null>(null);

	$effect(() => {
		if (open) error = null;
	});

	async function confirm(event: Event) {
		event.preventDefault();
		busy = true;
		try {
			await onconfirm();
			open = false;
		} catch (e) {
			error =
				e instanceof ApiError ? e.reason : e instanceof Error ? e.message : 'The request failed.';
		} finally {
			busy = false;
		}
	}
</script>

<AlertDialog.Root bind:open>
	<AlertDialog.Content>
		<AlertDialog.Header>
			<AlertDialog.Title>{title}</AlertDialog.Title>
			<AlertDialog.Description>{description}</AlertDialog.Description>
		</AlertDialog.Header>
		{#if error}<p role="alert" class="text-sm text-loss">{error}</p>{/if}
		<AlertDialog.Footer>
			<AlertDialog.Cancel>Cancel</AlertDialog.Cancel>
			<AlertDialog.Action
				class={buttonVariants({ variant: 'destructive' })}
				onclick={confirm}
				disabled={busy}
			>
				{busy ? 'Working…' : confirmLabel}
			</AlertDialog.Action>
		</AlertDialog.Footer>
	</AlertDialog.Content>
</AlertDialog.Root>
