<script lang="ts">
	import {
		columnFilteringFeature,
		createFilteredRowModel,
		createPaginatedRowModel,
		createSortedRowModel,
		createTable,
		filterFn_includesString,
		globalFilteringFeature,
		rowPaginationFeature,
		rowSortingFeature,
		sortFn_alphanumeric,
		tableFeatures,
		type ColumnDef
	} from '@tanstack/svelte-table';
	import { untrack } from 'svelte';
	import { ArrowDown, ArrowUp, ChevronLeft, ChevronRight, Search } from '@lucide/svelte';
	import Delta from './delta.svelte';
	import PlatformDot from './platform-dot.svelte';
	import Sparkline from './sparkline.svelte';
	import { Button } from '$lib/components/ui/button';
	import { Input } from '$lib/components/ui/input';
	import type { MetricType } from '$lib/api/types';
	import type { ResourceRow } from '$lib/data/types';
	import { compact, formatRelative, kindLabel, METRICS, platformLabel, whole } from '$lib/format';
	import { withScope } from '$lib/scope.svelte';

	/**
	 * Every resource in scope, sortable by any column, filterable by name, paged.
	 *
	 * `trendMetric` drives the change and sparkline columns; `metrics` are the value columns shown
	 * beside it. The rows arrive already scoped and sorted by the source, and the table then owns
	 * the interactive re-sorting, so clicking a header never costs a request.
	 */
	let {
		rows,
		trendMetric,
		metrics,
		pageSize = 10,
		caption
	}: {
		rows: ResourceRow[];
		trendMetric: MetricType;
		metrics: MetricType[];
		pageSize?: number;
		caption: string;
	} = $props();

	const features = tableFeatures({
		rowSortingFeature,
		sortedRowModel: createSortedRowModel(),
		sortFns: { alphanumeric: sortFn_alphanumeric },
		columnFilteringFeature,
		globalFilteringFeature,
		filteredRowModel: createFilteredRowModel(),
		filterFns: { includesString: filterFn_includesString },
		rowPaginationFeature,
		paginatedRowModel: createPaginatedRowModel()
	});

	const change = (row: ResourceRow, type: MetricType): number | undefined => {
		const now = row.latest[type];
		const start = row.atStart[type];
		return now === undefined || start === undefined ? undefined : now - start;
	};

	// Built once per set of value columns. A metric with no reading sorts last whichever way the
	// column is ordered, so "no data" never masquerades as the smallest or largest value.
	const columns = $derived<ColumnDef<typeof features, ResourceRow>[]>([
		{ id: 'name', accessorFn: (row) => row.name, header: 'Name', sortFn: 'alphanumeric' },
		{ id: 'platform', accessorFn: (row) => platformLabel(row.platform), header: 'Platform' },
		{ id: 'kind', accessorFn: (row) => kindLabel(row.kind), header: 'Kind' },
		...metrics.map((type): ColumnDef<typeof features, ResourceRow> => ({
			id: type,
			accessorFn: (row) => row.latest[type],
			header: METRICS[type].short,
			sortUndefined: 'last',
			sortDescFirst: true
		})),
		{
			id: 'change',
			accessorFn: (row) => change(row, trendMetric),
			header: `Δ ${METRICS[trendMetric].short}`,
			sortUndefined: 'last',
			sortDescFirst: true
		},
		{ id: 'trend', header: 'Trend', enableSorting: false },
		{
			id: 'collected',
			accessorFn: (row) => (row.lastCollectedAt ? Date.parse(row.lastCollectedAt) : undefined),
			header: 'Last reading',
			sortUndefined: 'last',
			sortDescFirst: true
		}
	]);

	const table = createTable({
		features,
		get columns() {
			return columns;
		},
		get data() {
			return rows;
		},
		globalFilterFn: 'includesString',
		getColumnCanGlobalFilter: (column) => ['name', 'platform', 'kind'].includes(column.id),
		enableSortingRemoval: false,
		// The page size is a starting point, not a live binding; the table owns paging after that.
		initialState: { pagination: { pageIndex: 0, pageSize: untrack(() => pageSize) } }
	});

	const numericColumns = new Set<string>(['change', 'collected']);
	const isNumeric = (id: string) => numericColumns.has(id) || id in METRICS;

	const filtered = $derived(table.getFilteredRowModel().rows.length);
	const pagination = $derived(table.atoms.pagination.get());
	const globalFilter = $derived(table.atoms.globalFilter.get() ?? '');
</script>

<div class="flex flex-col gap-3">
	<div class="flex items-center gap-2">
		<div class="relative w-full max-w-64">
			<Search
				class="pointer-events-none absolute top-1/2 left-2.5 size-3.5 -translate-y-1/2 text-muted-foreground"
			/>
			<Input
				value={globalFilter}
				oninput={(e) => {
					table.setGlobalFilter(e.currentTarget.value);
					table.setPageIndex(0);
				}}
				placeholder="Filter by name, platform or kind"
				aria-label="Filter resources"
				class="h-8 pl-8 text-sm"
			/>
		</div>
		<span class="ml-auto text-xs whitespace-nowrap text-muted-foreground">
			{filtered === rows.length
				? `${whole(rows.length)} resources`
				: `${whole(filtered)} of ${whole(rows.length)}`}
		</span>
	</div>

	<div class="overflow-x-auto rounded-lg border">
		<table class="w-full min-w-[720px] text-sm">
			<caption class="sr-only">{caption}</caption>
			<thead class="bg-muted/50">
				{#each table.getHeaderGroups() as group (group.id)}
					<tr>
						{#each group.headers as header (header.id)}
							{@const sorted = header.column.getIsSorted()}
							<th
								scope="col"
								aria-sort={sorted === 'asc'
									? 'ascending'
									: sorted === 'desc'
										? 'descending'
										: undefined}
								class="px-3 py-2 text-xs font-medium whitespace-nowrap text-muted-foreground {isNumeric(
									header.id
								)
									? 'text-right'
									: 'text-left'}"
							>
								{#if header.column.getCanSort()}
									<button
										type="button"
										class="inline-flex items-center gap-1 hover:text-foreground {isNumeric(
											header.id
										)
											? 'flex-row-reverse'
											: ''}"
										onclick={header.column.getToggleSortingHandler()}
									>
										{header.column.columnDef.header}
										{#if sorted === 'asc'}<ArrowUp
												class="size-3"
											/>{:else if sorted === 'desc'}<ArrowDown class="size-3" />{/if}
									</button>
								{:else}
									{header.column.columnDef.header}
								{/if}
							</th>
						{/each}
					</tr>
				{/each}
			</thead>
			<tbody>
				{#each table.getRowModel().rows as row (row.id)}
					{@const r = row.original}
					<tr class="border-t hover:bg-muted/40">
						<td class="max-w-64 px-3 py-2">
							<a
								href={withScope(`/resources/${r.id}`, ['range'])}
								class="block truncate font-medium hover:underline"
								title={r.name}>{r.name}</a
							>
							{#if r.account}<span class="block truncate text-xs text-muted-foreground"
									>{r.account}</span
								>{/if}
						</td>
						<td class="px-3 py-2 whitespace-nowrap"><PlatformDot platform={r.platform} /></td>
						<td class="px-3 py-2 whitespace-nowrap text-muted-foreground">{kindLabel(r.kind)}</td>
						{#each metrics as type (type)}
							<td class="numeric px-3 py-2 text-right" title={whole(r.latest[type])}
								>{compact(r.latest[type])}</td
							>
						{/each}
						<td class="px-3 py-2 text-right">
							{#if r.latest[trendMetric] !== undefined}
								<Delta
									current={r.latest[trendMetric]!}
									start={r.atStart[trendMetric] ?? null}
									mode="absolute"
								/>
							{:else}<span class="text-muted-foreground">—</span>{/if}
						</td>
						<td class="px-3 py-2">
							<Sparkline
								points={r.spark}
								width={72}
								height={20}
								label="{r.name} {METRICS[trendMetric].short} trend"
							/>
						</td>
						<td class="px-3 py-2 text-right text-xs whitespace-nowrap text-muted-foreground"
							>{formatRelative(r.lastCollectedAt)}</td
						>
					</tr>
				{:else}
					<tr
						><td colspan={columns.length} class="px-3 py-8 text-center text-muted-foreground"
							>No resources match.</td
						></tr
					>
				{/each}
			</tbody>
		</table>
	</div>

	{#if table.getPageCount() > 1}
		<div class="flex items-center justify-end gap-2 text-xs">
			<span class="text-muted-foreground"
				>Page {pagination.pageIndex + 1} of {table.getPageCount()}</span
			>
			<Button
				variant="outline"
				size="icon-sm"
				onclick={() => table.previousPage()}
				disabled={!table.getCanPreviousPage()}
				aria-label="Previous page"><ChevronLeft /></Button
			>
			<Button
				variant="outline"
				size="icon-sm"
				onclick={() => table.nextPage()}
				disabled={!table.getCanNextPage()}
				aria-label="Next page"><ChevronRight /></Button
			>
		</div>
	{/if}
</div>
