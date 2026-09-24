<script lang="ts" module>
	import type { Point } from '$lib/data/types';

	export interface TrendSeries {
		key: string;
		label: string;
		color: string;
		points: Point[];
	}
</script>

<script lang="ts">
	import { scaleLinear, scaleUtc } from 'd3-scale';
	import { compact, formatDate, formatShortDate, whole } from '$lib/format';

	/**
	 * Totals over time, one line per series on a single y-axis.
	 *
	 * Follows the dataviz mark specs: 2px lines, a 10% wash under a lone series, hairline grid,
	 * a crosshair that snaps to the nearest date and lists every series in one tooltip, direct
	 * end labels only while they don't collide, and a table view carrying every value so the
	 * tooltip is never the only way to read one.
	 */
	let {
		series,
		label,
		height = 260
	}: { series: TrendSeries[]; label: string; height?: number } = $props();

	let width = $state(640);
	let hover = $state<number | null>(null);
	let showTable = $state(false);

	const MARGIN = { top: 12, bottom: 26, left: 44 };

	const drawn = $derived(series.filter((s) => s.points.length > 0));
	const times = $derived([...new Set(drawn.flatMap((s) => s.points.map((p) => p.t)))].sort());
	const single = $derived(drawn.length === 1);

	// End labels: the value for a lone series, the series name when there are a few. Dropped as
	// soon as two would sit closer than a line of text, because nudging them apart detaches them
	// from their lines; the legend and tooltip carry identity then.
	const endLabels = $derived.by(() => {
		if (drawn.length === 0 || drawn.length > 4) return [];
		return drawn.map((s) => ({ s, last: s.points[s.points.length - 1] }));
	});

	const right = $derived(endLabels.length ? (single ? 56 : 104) : 12);

	const x = $derived(
		scaleUtc()
			.domain(
				times.length
					? [new Date(`${times[0]}T00:00:00Z`), new Date(`${times[times.length - 1]}T00:00:00Z`)]
					: [new Date(), new Date()]
			)
			.range([MARGIN.left, Math.max(MARGIN.left + 10, width - right)])
	);

	const y = $derived.by(() => {
		const values = drawn.flatMap((s) => s.points.map((p) => p.v));
		const max = values.length ? Math.max(...values) : 1;
		// From zero: these are counts, and a baseline anywhere else exaggerates small changes.
		return scaleLinear()
			.domain([0, max || 1])
			.nice(4)
			.range([height - MARGIN.bottom, MARGIN.top]);
	});

	const xAt = (t: string) => x(new Date(`${t}T00:00:00Z`));

	const line = (points: Point[]) =>
		points.map((p, i) => `${i ? 'L' : 'M'}${xAt(p.t).toFixed(1)},${y(p.v).toFixed(1)}`).join('');

	const area = (points: Point[]) =>
		points.length
			? `${line(points)}L${xAt(points[points.length - 1].t).toFixed(1)},${y(0)}L${xAt(points[0].t).toFixed(1)},${y(0)}Z`
			: '';

	const labelsCollide = $derived.by(() => {
		const ys = endLabels.map(({ last }) => y(last.v)).sort((a, b) => a - b);
		return ys.some((value, i) => i > 0 && value - ys[i - 1] < 14);
	});

	const xTicks = $derived(x.ticks(Math.max(2, Math.floor((width - MARGIN.left - right) / 110))));
	const yTicks = $derived(y.ticks(4));

	/** The value each series held at a date, carried from its last point on or before it. */
	function valueAt(s: TrendSeries, t: string): number | null {
		let value: number | null = null;
		for (const p of s.points) {
			if (p.t > t) break;
			value = p.v;
		}
		return value;
	}

	function nearestIndex(clientX: number, rect: DOMRect): number {
		const target = clientX - rect.left;
		let best = 0;
		let bestDistance = Infinity;
		times.forEach((t, i) => {
			const distance = Math.abs(xAt(t) - target);
			if (distance < bestDistance) {
				best = i;
				bestDistance = distance;
			}
		});
		return best;
	}

	function onKey(event: KeyboardEvent) {
		if (!times.length) return;
		if (event.key === 'ArrowLeft' || event.key === 'ArrowRight') {
			event.preventDefault();
			const step = event.key === 'ArrowLeft' ? -1 : 1;
			hover = Math.min(times.length - 1, Math.max(0, (hover ?? times.length - 1) + step));
		} else if (event.key === 'Escape') {
			hover = null;
		}
	}

	const hoverT = $derived(hover === null ? null : times[hover]);
	const tooltipRows = $derived(
		hoverT === null
			? []
			: drawn
					.map((s) => ({ s, v: valueAt(s, hoverT) }))
					.filter((row) => row.v !== null)
					.sort((a, b) => b.v! - a.v!)
	);
</script>

<div class="flex flex-col gap-3">
	{#if drawn.length > 1}
		<ul class="flex flex-wrap gap-x-4 gap-y-1 text-xs" aria-label="Legend">
			{#each drawn as s (s.key)}
				<li class="flex items-center gap-1.5 text-muted-foreground">
					<span class="inline-block h-0.5 w-3 rounded-full" style="background:{s.color}"
					></span>{s.label}
				</li>
			{/each}
		</ul>
	{/if}

	<div class="relative" bind:clientWidth={width}>
		{#if times.length === 0}
			<div
				class="flex items-center justify-center text-sm text-muted-foreground"
				style="height:{height}px"
			>
				No readings in this range.
			</div>
		{:else}
			<!-- The chart is a keyboard control (arrow keys walk the dates), so it takes focus and
			     listens; Svelte's check treats every <svg> as static regardless of its role. -->
			<!-- svelte-ignore a11y_no_noninteractive_tabindex, a11y_no_noninteractive_element_interactions -->
			<svg
				{width}
				{height}
				role="application"
				aria-roledescription="chart"
				aria-label="{label}. Use the left and right arrow keys to read values by date."
				tabindex="0"
				class="block rounded-md outline-none focus-visible:ring-3 focus-visible:ring-ring/50"
				onpointermove={(e) =>
					(hover = nearestIndex(e.clientX, e.currentTarget.getBoundingClientRect()))}
				onpointerleave={() => (hover = null)}
				onkeydown={onKey}
				onblur={() => (hover = null)}
			>
				{#each yTicks as tick (tick)}
					<line
						x1={MARGIN.left}
						x2={width - right}
						y1={y(tick)}
						y2={y(tick)}
						stroke={tick === 0 ? 'var(--border)' : 'var(--grid)'}
						stroke-width="1"
					/>
					<text
						x={MARGIN.left - 8}
						y={y(tick)}
						dy="0.32em"
						text-anchor="end"
						class="numeric fill-muted-foreground text-[11px]">{compact(tick)}</text
					>
				{/each}
				{#each xTicks as tick (tick.getTime())}
					<text
						x={x(tick)}
						y={height - 6}
						text-anchor="middle"
						class="fill-muted-foreground text-[11px]">{formatShortDate(tick)}</text
					>
				{/each}

				{#each drawn as s (s.key)}
					{#if single}
						<path d={area(s.points)} fill={s.color} fill-opacity="0.1" />
					{/if}
					<path
						d={line(s.points)}
						fill="none"
						stroke={s.color}
						stroke-width="2"
						stroke-linejoin="round"
						stroke-linecap="round"
					/>
				{/each}

				{#if !labelsCollide}
					{#each endLabels as { s, last } (s.key)}
						<circle
							cx={xAt(last.t)}
							cy={y(last.v)}
							r="4"
							fill={s.color}
							stroke="var(--card)"
							stroke-width="2"
						/>
						<text
							x={xAt(last.t) + 9}
							y={y(last.v)}
							dy="0.32em"
							class="fill-foreground text-[11px] font-medium"
						>
							{single ? compact(last.v) : s.label}
						</text>
					{/each}
				{/if}

				{#if hoverT !== null}
					<line
						x1={xAt(hoverT)}
						x2={xAt(hoverT)}
						y1={MARGIN.top}
						y2={height - MARGIN.bottom}
						stroke="var(--muted-foreground)"
						stroke-width="1"
					/>
					{#each tooltipRows as row (row.s.key)}
						<circle
							cx={xAt(hoverT)}
							cy={y(row.v!)}
							r="4"
							fill={row.s.color}
							stroke="var(--card)"
							stroke-width="2"
						/>
					{/each}
				{/if}
			</svg>

			{#if hoverT !== null}
				{@const left = xAt(hoverT)}
				<div
					class="pointer-events-none absolute top-2 z-10 min-w-36 rounded-lg border bg-popover px-3 py-2 text-xs text-popover-foreground shadow-md"
					style={left > width / 2 ? `right:${width - left + 12}px` : `left:${left + 12}px`}
					role="status"
				>
					<div class="mb-1 text-muted-foreground">{formatDate(hoverT)}</div>
					{#each tooltipRows as row (row.s.key)}
						<div class="flex items-center gap-2">
							<span class="inline-block h-0.5 w-3 rounded-full" style="background:{row.s.color}"
							></span>
							<span class="numeric font-semibold">{whole(row.v)}</span>
							<span class="truncate text-muted-foreground">{row.s.label}</span>
						</div>
					{/each}
				</div>
			{/if}
		{/if}
	</div>

	{#if times.length}
		<div>
			<button
				type="button"
				class="text-xs text-muted-foreground underline-offset-4 hover:text-foreground hover:underline"
				onclick={() => (showTable = !showTable)}
				aria-expanded={showTable}
			>
				{showTable ? 'Hide data table' : 'Show data table'}
			</button>
			{#if showTable}
				<div class="mt-2 max-h-72 overflow-auto rounded-lg border">
					<table class="numeric w-full text-xs">
						<caption class="sr-only">{label}</caption>
						<thead class="sticky top-0 bg-muted/60">
							<tr>
								<th scope="col" class="px-3 py-1.5 text-left font-medium">Date</th>
								{#each drawn as s (s.key)}
									<th scope="col" class="px-3 py-1.5 text-right font-medium">{s.label}</th>
								{/each}
							</tr>
						</thead>
						<tbody>
							{#each [...times].reverse() as t (t)}
								<tr class="border-t">
									<th scope="row" class="px-3 py-1 text-left font-normal">{formatDate(t)}</th>
									{#each drawn as s (s.key)}
										<td class="px-3 py-1 text-right">{whole(valueAt(s, t))}</td>
									{/each}
								</tr>
							{/each}
						</tbody>
					</table>
				</div>
			{/if}
		</div>
	{/if}
</div>
