<script lang="ts">
	import { Ellipsis } from '@lucide/svelte';
	import * as DropdownMenu from '$lib/components/ui/dropdown-menu';
	import { Button } from '$lib/components/ui/button';

	/**
	 * One quiet menu per row instead of an Edit and a Delete button on every line of a table.
	 *
	 * An action that cannot run says why in its own label rather than silently greying out, since a
	 * disabled control gives no hint on touch screens.
	 */
	let {
		label,
		actions
	}: {
		label: string;
		actions: {
			label: string;
			onselect: () => void;
			destructive?: boolean;
			blockedBecause?: string | null;
		}[];
	} = $props();
</script>

<DropdownMenu.Root>
	<DropdownMenu.Trigger>
		{#snippet child({ props })}
			<Button {...props} variant="ghost" size="icon-sm" aria-label="Actions for {label}"
				><Ellipsis /></Button
			>
		{/snippet}
	</DropdownMenu.Trigger>
	<DropdownMenu.Content align="end" class="w-56">
		{#each actions as action (action.label)}
			<DropdownMenu.Item
				variant={action.destructive ? 'destructive' : 'default'}
				disabled={!!action.blockedBecause}
				onSelect={action.onselect}
				class="flex-col items-start gap-0"
			>
				<span>{action.label}</span>
				{#if action.blockedBecause}<span class="text-xs text-muted-foreground"
						>{action.blockedBecause}</span
					>{/if}
			</DropdownMenu.Item>
		{/each}
	</DropdownMenu.Content>
</DropdownMenu.Root>
