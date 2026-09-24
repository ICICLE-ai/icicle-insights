<script lang="ts">
	import { toast } from 'svelte-sonner';
	import { Plus } from '@lucide/svelte';
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
	import { adminApi, isRecordable } from '$lib/admin/api';
	import type { Metric, MetricType } from '$lib/api/types';
	import { formatDate, formatRelative, METRIC_ORDER, metricLabel, whole } from '$lib/format';
	import { query } from '$lib/query.svelte';

	/**
	 * The newest readings, for correcting one by hand or recording one no collector can.
	 *
	 * Every manual change is folded into the matching all-time total by the server — adding a reading
	 * adds to it, editing moves it by the difference, deleting takes it back out. All-time rows
	 * themselves can't be recorded or edited, only deleted, which the server allows as the last
	 * resort for a total that has gone wrong.
	 */
	const data = query(async () => {
		const [metrics, resources] = await Promise.all([
			adminApi.recentMetrics(100),
			adminApi.resources()
		]);
		const names = new Map(resources.map((r) => [r.id?.toLowerCase() ?? '', r.name ?? '']));
		return { metrics, resources, names };
	});

	const RECORDABLE = METRIC_ORDER.filter(isRecordable);

	let sheetOpen = $state(false);
	let editing = $state<Metric | null>(null);
	let resourceID = $state('');
	let type = $state<MetricType>('stars');
	let reading = $state('');

	function openCreate() {
		editing = null;
		resourceID = '';
		type = 'stars';
		reading = '';
		sheetOpen = true;
	}

	function openEdit(metric: Metric) {
		editing = metric;
		type = metric.type ?? 'stars';
		reading = String(metric.reading ?? '');
		sheetOpen = true;
	}

	let deleting = $state<Metric | null>(null);
	let confirmOpen = $state(false);
</script>

<div class="flex flex-col gap-5">
	<div class="flex flex-wrap items-end justify-between gap-3">
		<div>
			<h1 class="text-xl font-semibold tracking-tight">Metrics</h1>
			<p class="max-w-2xl text-sm text-muted-foreground">
				The 100 newest readings. Manual changes also adjust the matching all-time total.
			</p>
		</div>
		<Button onclick={openCreate}><Plus /> Record reading</Button>
	</div>

	{#if data.error && !data.data}
		<LoadError error={data.error} retry={data.refresh} />
	{:else if !data.data}
		<Skeleton class="h-96 rounded-xl" />
	{:else}
		<div class="overflow-x-auto rounded-xl border bg-card">
			<table class="w-full min-w-[600px] text-sm">
				<caption class="sr-only">Newest metric readings</caption>
				<thead class="bg-muted/50 text-xs text-muted-foreground">
					<tr>
						<th scope="col" class="px-4 py-2 text-left font-medium">Resource</th>
						<th scope="col" class="px-4 py-2 text-left font-medium">Metric</th>
						<th scope="col" class="px-4 py-2 text-right font-medium">Reading</th>
						<th scope="col" class="px-4 py-2 text-right font-medium">Recorded</th>
						<th scope="col" class="w-10 px-2 py-2"><span class="sr-only">Actions</span></th>
					</tr>
				</thead>
				<tbody>
					{#each [...data.data.metrics].reverse() as metric (metric.id)}
						{@const name = data.data.names.get(metric.resourceID?.toLowerCase() ?? '') ?? 'Unknown'}
						{@const derived = !isRecordable(metric.type ?? '')}
						<tr class="border-t">
							<td class="max-w-64 truncate px-4 py-2 font-medium" title={name}>{name}</td>
							<td class="px-4 py-2 text-muted-foreground">{metricLabel(metric.type ?? '')}</td>
							<td class="numeric px-4 py-2 text-right">{whole(metric.reading)}</td>
							<td
								class="px-4 py-2 text-right text-muted-foreground"
								title={formatDate(metric.recordedAt)}>{formatRelative(metric.recordedAt)}</td
							>
							<td class="px-2 py-1 text-right">
								<RowActions
									label="{name} {metricLabel(metric.type ?? '')}"
									actions={[
										{
											label: 'Correct reading',
											blockedBecause: derived ? 'All-time totals are derived by the server' : null,
											onselect: () => openEdit(metric)
										},
										{
											label: 'Delete reading',
											destructive: true,
											onselect: () => ((deleting = metric), (confirmOpen = true))
										}
									]}
								/>
							</td>
						</tr>
					{:else}
						<tr
							><td colspan="5" class="px-4 py-10 text-center text-muted-foreground"
								>No readings yet.</td
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
	title={editing ? 'Correct reading' : 'Record reading'}
	description={editing
		? 'The all-time total moves by the difference between the old and new value.'
		: 'For a figure no collector reports. It is also added to the all-time total.'}
	submitLabel={editing ? 'Save correction' : 'Record reading'}
	validate={() => {
		if (!editing && !resourceID) return 'Choose the resource this reading is for.';
		const value = Number(reading);
		if (reading.trim() === '' || !Number.isFinite(value) || value < 0)
			return 'Enter a reading of zero or more.';
		return null;
	}}
	onsubmit={async () => {
		if (editing) await adminApi.updateMetric(editing.id!, { reading: Number(reading), type });
		else await adminApi.createMetric({ resourceID, type, reading: Number(reading) });
		toast.success(editing ? 'Reading corrected' : 'Reading recorded');
		data.refresh();
	}}
>
	{#if !editing}
		<Field id="metric-resource" label="Resource">
			<ResourcePicker
				id="metric-resource"
				resources={data.data?.resources ?? []}
				bind:value={resourceID}
			/>
		</Field>
	{/if}
	<Field id="metric-type" label="Metric">
		<Select.Root type="single" bind:value={type}>
			<Select.Trigger id="metric-type" class="w-full">{metricLabel(type)}</Select.Trigger>
			<Select.Content>
				{#each RECORDABLE as t (t)}<Select.Item value={t} label={metricLabel(t)} />{/each}
			</Select.Content>
		</Select.Root>
	</Field>
	<Field id="metric-reading" label="Reading">
		<Input id="metric-reading" type="number" min="0" step="any" bind:value={reading} />
	</Field>
</FormSheet>

<ConfirmAction
	bind:open={confirmOpen}
	title="Delete this reading?"
	description={deleting && !isRecordable(deleting.type ?? '')
		? 'This is an all-time total. Deleting it resets the total; collection rebuilds it from the next uncounted day, not from the beginning.'
		: 'The reading is removed and taken back out of its all-time total.'}
	confirmLabel="Delete reading"
	onconfirm={async () => {
		await adminApi.deleteMetric(deleting!.id!);
		toast.success('Reading deleted');
		data.refresh();
	}}
/>
