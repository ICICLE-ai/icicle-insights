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
	import ResourcePicker from '$lib/components/admin/resource-picker.svelte';
	import RowActions from '$lib/components/admin/row-actions.svelte';
	import LoadError from '$lib/components/load-error.svelte';
	import { adminApi } from '$lib/admin/api';
	import type { Release } from '$lib/api/types';
	import { pluralize } from '$lib/format';
	import { query } from '$lib/query.svelte';

	/** Published versions, recorded by hand to month precision, which is what the API stores. */
	const data = query(async () => {
		const [releases, resources] = await Promise.all([adminApi.releases(), adminApi.resources()]);
		const names = new Map(resources.map((r) => [r.id?.toLowerCase() ?? '', r.name ?? '']));
		return { releases, resources, names };
	});

	const MONTHS = Array.from({ length: 12 }, (_, i) =>
		new Date(Date.UTC(2000, i, 1)).toLocaleString('en-US', { month: 'long', timeZone: 'UTC' })
	);
	const monthYear = (iso?: string | null) =>
		iso
			? new Date(iso).toLocaleString('en-US', { month: 'short', year: 'numeric', timeZone: 'UTC' })
			: '—';

	let filter = $state('');
	const rows = $derived(
		(data.data?.releases ?? [])
			.map((r) => ({
				...r,
				resourceName: data.data?.names.get(r.resourceID?.toLowerCase() ?? '') ?? 'Unknown'
			}))
			.filter(
				(r) =>
					!filter || `${r.resourceName} ${r.version}`.toLowerCase().includes(filter.toLowerCase())
			)
			.sort((a, b) => (b.releasedAt ?? '').localeCompare(a.releasedAt ?? ''))
	);

	let sheetOpen = $state(false);
	let editing = $state<Release | null>(null);
	let resourceID = $state('');
	let version = $state('');
	let month = $state(String(new Date().getUTCMonth() + 1));
	let year = $state(String(new Date().getUTCFullYear()));

	function openCreate() {
		editing = null;
		resourceID = '';
		version = '';
		month = String(new Date().getUTCMonth() + 1);
		year = String(new Date().getUTCFullYear());
		sheetOpen = true;
	}

	function openEdit(release: Release) {
		editing = release;
		const date = release.releasedAt ? new Date(release.releasedAt) : new Date();
		version = release.version ?? '';
		month = String(date.getUTCMonth() + 1);
		year = String(date.getUTCFullYear());
		sheetOpen = true;
	}

	let deleting = $state<Release | null>(null);
	let confirmOpen = $state(false);
</script>

<div class="flex flex-col gap-5">
	<div class="flex flex-wrap items-end justify-between gap-3">
		<div>
			<h1 class="text-xl font-semibold tracking-tight">Releases</h1>
			<p class="text-sm text-muted-foreground">
				{data.data ? pluralize(data.data.releases.length, 'release') : ''} recorded.
			</p>
		</div>
		<Button onclick={openCreate}><Plus /> Add release</Button>
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
				placeholder="Filter by resource or version"
				aria-label="Filter releases"
				class="h-8 pl-8"
			/>
		</div>
		<div class="overflow-x-auto rounded-xl border bg-card">
			<table class="w-full min-w-[520px] text-sm">
				<caption class="sr-only">Recorded releases</caption>
				<thead class="bg-muted/50 text-xs text-muted-foreground">
					<tr>
						<th scope="col" class="px-4 py-2 text-left font-medium">Resource</th>
						<th scope="col" class="px-4 py-2 text-left font-medium">Version</th>
						<th scope="col" class="px-4 py-2 text-right font-medium">Released</th>
						<th scope="col" class="w-10 px-2 py-2"><span class="sr-only">Actions</span></th>
					</tr>
				</thead>
				<tbody>
					{#each rows as release (release.id)}
						<tr class="border-t">
							<td class="px-4 py-2 font-medium">{release.resourceName}</td>
							<td class="px-4 py-2 font-mono text-xs">{release.version}</td>
							<td class="px-4 py-2 text-right text-muted-foreground"
								>{monthYear(release.releasedAt)}</td
							>
							<td class="px-2 py-1 text-right">
								<RowActions
									label="{release.resourceName} {release.version}"
									actions={[
										{ label: 'Edit', onselect: () => openEdit(release) },
										{
											label: 'Delete release',
											destructive: true,
											onselect: () => ((deleting = release), (confirmOpen = true))
										}
									]}
								/>
							</td>
						</tr>
					{:else}
						<tr
							><td colspan="4" class="px-4 py-10 text-center text-muted-foreground"
								>{filter ? 'Nothing matches.' : 'No releases recorded.'}</td
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
	title={editing ? `Edit ${editing.version}` : 'Add release'}
	submitLabel={editing ? 'Save changes' : 'Add release'}
	validate={() => {
		if (!editing && !resourceID) return 'Choose the resource this release belongs to.';
		if (!version.trim()) return 'Enter the version.';
		const y = Number(year);
		if (!Number.isInteger(y) || y < 2000 || y > 2100) return 'Enter a four-digit year.';
		return null;
	}}
	onsubmit={async () => {
		const body = { version: version.trim(), month: Number(month), year: Number(year) };
		if (editing) await adminApi.updateRelease(editing.id!, body);
		else await adminApi.createRelease({ ...body, resourceID });
		toast.success(editing ? `Saved ${body.version}` : `Added ${body.version}`);
		data.refresh();
	}}
>
	{#if !editing}
		<Field id="release-resource" label="Resource">
			<ResourcePicker
				id="release-resource"
				resources={data.data?.resources ?? []}
				bind:value={resourceID}
			/>
		</Field>
	{/if}
	<Field id="release-version" label="Version">
		<Input
			id="release-version"
			bind:value={version}
			placeholder="1.4.0"
			autocomplete="off"
			class="font-mono"
		/>
	</Field>
	<div class="grid grid-cols-2 gap-3">
		<Field id="release-month" label="Month">
			<Select.Root type="single" bind:value={month}>
				<Select.Trigger id="release-month" class="w-full"
					>{MONTHS[Number(month) - 1]}</Select.Trigger
				>
				<Select.Content>
					{#each MONTHS as label, i (label)}<Select.Item value={String(i + 1)} {label} />{/each}
				</Select.Content>
			</Select.Root>
		</Field>
		<Field id="release-year" label="Year">
			<Input id="release-year" type="number" min="2000" max="2100" step="1" bind:value={year} />
		</Field>
	</div>
</FormSheet>

<ConfirmAction
	bind:open={confirmOpen}
	title="Delete {deleting?.version}?"
	description="The release is removed from the catalog and the release charts."
	confirmLabel="Delete release"
	onconfirm={async () => {
		await adminApi.deleteRelease(deleting!.id!);
		toast.success(`Deleted ${deleting?.version}`);
		data.refresh();
	}}
/>
