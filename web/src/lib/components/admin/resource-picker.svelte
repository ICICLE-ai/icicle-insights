<script lang="ts">
	import { Check, ChevronsUpDown } from '@lucide/svelte';
	import * as Command from '$lib/components/ui/command';
	import * as Popover from '$lib/components/ui/popover';
	import { Button } from '$lib/components/ui/button';
	import type { Resource } from '$lib/api/types';
	import { kindLabel } from '$lib/format';

	/** A searchable resource chooser for forms — a plain select is unusable at a hundred-plus rows. */
	let {
		id,
		resources,
		value = $bindable('')
	}: { id: string; resources: Resource[]; value?: string } = $props();

	let open = $state(false);
	const sorted = $derived(
		[...resources].sort((a, b) => (a.name ?? '').localeCompare(b.name ?? ''))
	);
	const selected = $derived(resources.find((r) => r.id?.toLowerCase() === value.toLowerCase()));
</script>

<Popover.Root bind:open>
	<Popover.Trigger>
		{#snippet child({ props })}
			<Button
				{...props}
				{id}
				variant="outline"
				role="combobox"
				aria-expanded={open}
				class="w-full justify-between font-normal"
			>
				<span class="truncate">{selected?.name ?? 'Choose a resource'}</span>
				<ChevronsUpDown class="text-muted-foreground" />
			</Button>
		{/snippet}
	</Popover.Trigger>
	<Popover.Content class="w-(--bits-popover-anchor-width) p-0" align="start">
		<Command.Root>
			<Command.Input placeholder="Search resources" />
			<Command.List class="max-h-64">
				<Command.Empty>No resource matches.</Command.Empty>
				{#each sorted as resource (resource.id)}
					<Command.Item
						value="{resource.name} {resource.id}"
						onSelect={() => {
							value = resource.id!;
							open = false;
						}}
					>
						<span class="truncate">{resource.name}</span>
						<span class="ml-auto text-xs text-muted-foreground">{kindLabel(resource.type)}</span>
						{#if selected?.id === resource.id}<Check />{/if}
					</Command.Item>
				{/each}
			</Command.List>
		</Command.Root>
	</Popover.Content>
</Popover.Root>
