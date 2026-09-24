<script lang="ts">
	import { goto } from '$app/navigation';
	import { Check, ChevronsUpDown, Layers } from '@lucide/svelte';
	import * as Command from '$lib/components/ui/command';
	import * as Popover from '$lib/components/ui/popover';
	import { Button } from '$lib/components/ui/button';
	import PlatformDot from './platform-dot.svelte';
	import type { Catalog } from '$lib/data/catalog';
	import { kindLabel, platformLabel, pluralize } from '$lib/format';
	import { platformParam, setParams, withScope } from '$lib/scope.svelte';

	/**
	 * One control for "what am I looking at": everything, one platform, or a jump to one resource.
	 *
	 * Searchable, because 110 resources is past what anyone scans in a dropdown. Choosing a platform
	 * filters the current page; choosing a resource opens its page, since a single resource has a
	 * different shape (its own tiles and releases) from a filtered aggregate.
	 */
	let { catalog }: { catalog: Catalog | null } = $props();

	let open = $state(false);

	const counts = $derived.by(() => {
		const map = new Map<string, number>();
		for (const platform of catalog?.platformOf.values() ?? [])
			map.set(platform, (map.get(platform) ?? 0) + 1);
		return map;
	});

	const resources = $derived(
		[...(catalog?.resources ?? [])].sort((a, b) => (a.name ?? '').localeCompare(b.name ?? ''))
	);

	const current = $derived(platformParam());

	async function choosePlatform(platform: string | null) {
		open = false;
		await setParams({ platform });
	}

	async function chooseResource(id: string) {
		open = false;
		await goto(withScope(`/resources/${id.toLowerCase()}`, ['range']));
	}
</script>

<Popover.Root bind:open>
	<Popover.Trigger>
		{#snippet child({ props })}
			<Button
				{...props}
				variant="outline"
				class="h-8 min-w-0 flex-1 justify-between gap-2 font-normal sm:max-w-72"
				aria-label="Choose what to show"
			>
				<span class="flex min-w-0 items-center gap-2">
					{#if current}
						<PlatformDot platform={current} />
					{:else}
						<Layers class="text-muted-foreground" />
						<span class="truncate">All platforms</span>
					{/if}
				</span>
				<span class="flex items-center gap-1 text-xs text-muted-foreground">
					<span class="hidden sm:inline"
						>{catalog
							? pluralize(
									current ? (counts.get(current) ?? 0) : catalog.resources.length,
									'resource'
								)
							: ''}</span
					>
					<ChevronsUpDown class="size-3.5" />
				</span>
			</Button>
		{/snippet}
	</Popover.Trigger>
	<Popover.Content class="w-80 p-0" align="start">
		<Command.Root>
			<Command.Input placeholder="Search platforms and resources" />
			<Command.List class="max-h-80">
				<Command.Empty>Nothing matches.</Command.Empty>
				<Command.Group heading="Platforms">
					<Command.Item value="all platforms" onSelect={() => choosePlatform(null)}>
						<Layers class="text-muted-foreground" />
						<span>All platforms</span>
						{#if !current}<Check class="ml-auto" />{/if}
					</Command.Item>
					{#each catalog?.platforms ?? [] as platform (platform)}
						<Command.Item
							value="platform {platformLabel(platform)}"
							onSelect={() => choosePlatform(platform)}
						>
							<PlatformDot {platform} />
							<span class="ml-auto text-xs text-muted-foreground">{counts.get(platform) ?? 0}</span>
							{#if current === platform}<Check />{/if}
						</Command.Item>
					{/each}
				</Command.Group>
				<Command.Separator />
				<Command.Group heading="Resources">
					{#each resources as resource (resource.id)}
						<Command.Item
							value="{resource.name} {resource.id}"
							onSelect={() => chooseResource(resource.id!)}
						>
							<span class="truncate">{resource.name}</span>
							<span class="ml-auto text-xs text-muted-foreground">{kindLabel(resource.type)}</span>
						</Command.Item>
					{/each}
				</Command.Group>
			</Command.List>
		</Command.Root>
	</Popover.Content>
</Popover.Root>
