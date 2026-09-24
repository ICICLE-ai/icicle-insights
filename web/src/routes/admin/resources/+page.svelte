<script lang="ts">
	import { toast } from 'svelte-sonner';
	import { Plus, Search } from '@lucide/svelte';
	import { Button } from '$lib/components/ui/button';
	import { Input } from '$lib/components/ui/input';
	import * as Select from '$lib/components/ui/select';
	import { Skeleton } from '$lib/components/ui/skeleton';
	import ConfirmAction from '$lib/components/admin/confirm-action.svelte';
	import Field from '$lib/components/admin/field.svelte';
	import FormSheet from '$lib/components/admin/form-sheet.svelte';
	import RowActions from '$lib/components/admin/row-actions.svelte';
	import LoadError from '$lib/components/load-error.svelte';
	import PlatformDot from '$lib/components/platform-dot.svelte';
	import { adminApi, MAX_CADENCE_DAYS } from '$lib/admin/api';
	import type { Account, Resource, ResourceType } from '$lib/api/types';
	import { formatRelative, KIND_LABELS, kindLabel, pluralize } from '$lib/format';
	import { query } from '$lib/query.svelte';

	/**
	 * The collectable catalog. Adding a resource collects it straight away and then on its cadence;
	 * the cadence is capped per platform so a missed sweep can't outrun the platform's retention
	 * window (seven days for GitHub traffic, whose window is fourteen).
	 */
	const data = query(async () => {
		const [resources, accounts] = await Promise.all([adminApi.resources(), adminApi.accounts()]);
		const accountByID = new Map(accounts.map((a) => [a.id?.toLowerCase() ?? '', a]));
		return { resources, accounts, accountByID };
	});

	let filter = $state('');
	const rows = $derived(
		(data.data?.resources ?? [])
			.filter((r) => {
				if (!filter) return true;
				const account = data.data?.accountByID.get(r.accountID?.toLowerCase() ?? '');
				return `${r.name} ${r.type} ${account?.name} ${account?.platform}`
					.toLowerCase()
					.includes(filter.toLowerCase());
			})
			.sort((a, b) => (a.name ?? '').localeCompare(b.name ?? ''))
	);

	// One sheet for create and edit: editing can't move a resource between accounts (the API
	// refuses), so the account picker only appears when creating.
	let sheetOpen = $state(false);
	let editing = $state<Resource | null>(null);
	let accountID = $state('');
	let name = $state('');
	let kind = $state<ResourceType>('repository');
	let cadence = $state('7');

	const account = $derived<Account | undefined>(
		data.data?.accountByID.get((editing?.accountID ?? accountID).toLowerCase())
	);
	const maxCadence = $derived(account?.platform ? MAX_CADENCE_DAYS[account.platform] : 30);

	function openCreate() {
		editing = null;
		accountID = data.data?.accounts[0]?.id ?? '';
		name = '';
		kind = 'repository';
		cadence = '7';
		sheetOpen = true;
	}

	function openEdit(resource: Resource) {
		editing = resource;
		name = resource.name ?? '';
		kind = resource.type ?? 'repository';
		cadence = String(resource.collectionIntervalDays ?? 7);
		sheetOpen = true;
	}

	function validate(): string | null {
		if (!editing && !accountID) return 'Choose the account that owns this resource.';
		if (!name.trim()) return 'Enter the resource name.';
		const days = Number(cadence);
		if (!Number.isInteger(days) || days < 1 || days > maxCadence)
			return `Cadence must be a whole number of days from 1 to ${maxCadence} on this platform.`;
		return null;
	}

	let deleting = $state<Resource | null>(null);
	let confirmOpen = $state(false);
</script>

<div class="flex flex-col gap-5">
	<div class="flex flex-wrap items-end justify-between gap-3">
		<div>
			<h1 class="text-xl font-semibold tracking-tight">Resources</h1>
			<p class="text-sm text-muted-foreground">
				{data.data ? pluralize(data.data.resources.length, 'resource') : ''} under collection. Each is
				collected on its own cadence.
			</p>
		</div>
		<Button onclick={openCreate} disabled={!data.data?.accounts.length}
			><Plus /> Add resource</Button
		>
	</div>

	{#if data.error && !data.data}
		<LoadError error={data.error} retry={data.refresh} />
	{:else if !data.data}
		<Skeleton class="h-96 rounded-xl" />
	{:else}
		<div class="relative w-full max-w-72">
			<Search
				class="pointer-events-none absolute top-1/2 left-2.5 size-3.5 -translate-y-1/2 text-muted-foreground"
			/>
			<Input
				bind:value={filter}
				placeholder="Filter by name, kind or account"
				aria-label="Filter resources"
				class="h-8 pl-8"
			/>
		</div>
		<div class="overflow-x-auto rounded-xl border bg-card">
			<table class="w-full min-w-[720px] text-sm">
				<caption class="sr-only">Resources under collection</caption>
				<thead class="bg-muted/50 text-xs text-muted-foreground">
					<tr>
						<th scope="col" class="px-4 py-2 text-left font-medium">Resource</th>
						<th scope="col" class="px-4 py-2 text-left font-medium">Kind</th>
						<th scope="col" class="px-4 py-2 text-left font-medium">Account</th>
						<th scope="col" class="px-4 py-2 text-right font-medium">Cadence</th>
						<th scope="col" class="px-4 py-2 text-right font-medium">Next collection</th>
						<th scope="col" class="w-10 px-2 py-2"><span class="sr-only">Actions</span></th>
					</tr>
				</thead>
				<tbody>
					{#each rows as resource (resource.id)}
						{@const owner = data.data.accountByID.get(resource.accountID?.toLowerCase() ?? '')}
						<tr class="border-t">
							<td class="max-w-72 truncate px-4 py-2 font-medium" title={resource.name}
								>{resource.name}</td
							>
							<td class="px-4 py-2 text-muted-foreground">{kindLabel(resource.type)}</td>
							<td class="px-4 py-2"
								><span class="flex items-center gap-2"
									><PlatformDot platform={owner?.platform} /><span class="text-muted-foreground"
										>{owner?.name}</span
									></span
								></td
							>
							<td class="numeric px-4 py-2 text-right"
								>{pluralize(resource.collectionIntervalDays ?? 7, 'day')}</td
							>
							<td class="px-4 py-2 text-right text-muted-foreground"
								>{resource.nextCollectionAt
									? formatRelative(resource.nextCollectionAt)
									: 'Not scheduled'}</td
							>
							<td class="px-2 py-1 text-right">
								<RowActions
									label={resource.name ?? 'resource'}
									actions={[
										{ label: 'Edit', onselect: () => openEdit(resource) },
										{
											label: 'Delete resource',
											destructive: true,
											onselect: () => ((deleting = resource), (confirmOpen = true))
										}
									]}
								/>
							</td>
						</tr>
					{:else}
						<tr
							><td colspan="6" class="px-4 py-10 text-center text-muted-foreground"
								>{filter ? 'Nothing matches.' : 'No resources yet.'}</td
							></tr
						>
					{/each}
				</tbody>
			</table>
		</div>
	{/if}
</div>

<FormSheet
	bind:open={sheetOpen}
	title={editing ? `Edit ${editing.name}` : 'Add resource'}
	description={editing
		? 'Name, kind and cadence. Moving a resource to another account means deleting and re-adding it.'
		: 'Collected right away, then on the cadence below.'}
	submitLabel={editing ? 'Save changes' : 'Add resource'}
	{validate}
	onsubmit={async () => {
		const body = { name: name.trim(), type: kind, collectionIntervalDays: Number(cadence) };
		if (editing) {
			await adminApi.updateResource(editing.id!, body);
			toast.success(`Saved ${body.name}`);
		} else {
			await adminApi.createResource({ ...body, accountID });
			toast.success(`Added ${body.name}; its first collection is queued`);
		}
		data.refresh();
	}}
>
	{#if !editing}
		<Field id="resource-account" label="Account">
			<Select.Root type="single" bind:value={accountID}>
				<Select.Trigger id="resource-account" class="w-full">
					{#if account}<PlatformDot platform={account.platform} /><span class="ml-1"
							>{account.name}</span
						>{:else}Choose an account{/if}
				</Select.Trigger>
				<Select.Content>
					{#each data.data?.accounts ?? [] as a (a.id)}<Select.Item
							value={a.id!}
							label="{a.name} · {a.platform}"
						/>{/each}
				</Select.Content>
			</Select.Root>
		</Field>
	{/if}
	<Field
		id="resource-name"
		label="Name"
		hint="The repository, model or package name as it appears in its URL. Stored lowercase."
	>
		<Input id="resource-name" bind:value={name} placeholder="camera_trap" autocomplete="off" />
	</Field>
	<Field id="resource-kind" label="Kind">
		<Select.Root type="single" bind:value={kind}>
			<Select.Trigger id="resource-kind" class="w-full">{kindLabel(kind)}</Select.Trigger>
			<Select.Content>
				{#each Object.entries(KIND_LABELS) as [value, label] (value)}<Select.Item
						{value}
						{label}
					/>{/each}
			</Select.Content>
		</Select.Root>
	</Field>
	<Field
		id="resource-cadence"
		label="Collect every (days)"
		hint="1 to {maxCadence} days on {account?.platform ?? 'this platform'}."
	>
		<Input
			id="resource-cadence"
			type="number"
			min="1"
			max={maxCadence}
			step="1"
			bind:value={cadence}
		/>
	</Field>
</FormSheet>

<ConfirmAction
	bind:open={confirmOpen}
	title="Delete {deleting?.name}?"
	description="Collection stops and it leaves the dashboard. Its collected history stays in the database."
	confirmLabel="Delete resource"
	onconfirm={async () => {
		await adminApi.deleteResource(deleting!.id!);
		toast.success(`Deleted ${deleting?.name}`);
		data.refresh();
	}}
/>
