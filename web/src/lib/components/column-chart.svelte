<script lang="ts">
	import { scaleBand, scaleLinear } from 'd3-scale';
	import { whole } from '$lib/format';

	/**
	 * Counts per period as columns on one baseline: ≤24px wide, 4px rounded tops, square at the
	 * base, one ink. Each column is its own hover and focus target and names its value, and the
	 * table view below repeats every value.
	 */
	let {
		data,
		label,
		unit,
		height = 200,
		color = 'var(--series-1)'
	}: {
		data: { key: string; label: string; value: number }[];
		label: string;
		unit: string;
		height?: number;
		color?: string;
	} = $props();

	let width = $state(600);
	let active = $state<string | null>(null);
	let showTable = $state(false);

	const MARGIN = { top: 16, bottom: 24, left: 32, right: 8 };

	const x = $derived(
		scaleBand()
			.domain(data.map((d) => d.key))
			.range([MARGIN.left, width - MARGIN.right])
			.paddingInner(0.25)
	);
	const y = $derived(
		scaleLinear()
			.domain([0, Math.max(1, ...data.map((d) => d.value))])
			.nice(4)
			.range([height - MARGIN.bottom, MARGIN.top])
	);
	const barWidth = $derived(Math.min(24, x.bandwidth()));
	// Label every nth period so axis text never overlaps, whatever the width.
	const labelEvery = $derived(
		Math.max(1, Math.ceil(data.length / Math.max(1, Math.floor((width - MARGIN.left) / 48))))
	);

	function columnPath(cx: number, top: number, w: number, base: number): string {
		const r = Math.min(4, w / 2, base - top);
		const left = cx - w / 2;
		return `M${left},${base}V${top + r}Q${left},${top} ${left + r},${top}H${left + w - r}Q${left + w},${top} ${left + w},${top + r}V${base}Z`;
	}

	const activeDatum = $derived(data.find((d) => d.key === active) ?? null);
</script>

<div class="flex flex-col gap-2">
	<div class="relative" bind:clientWidth={width}>
		<svg {width} {height} role="img" aria-label={label} class="block">
			{#each y.ticks(4) as tick (tick)}
				<line
					x1={MARGIN.left}
					x2={width - MARGIN.right}
					y1={y(tick)}
					y2={y(tick)}
					stroke={tick === 0 ? 'var(--border)' : 'var(--grid)'}
				/>
				<text
					x={MARGIN.left - 6}
					y={y(tick)}
					dy="0.32em"
					text-anchor="end"
					class="numeric fill-muted-foreground text-[11px]">{whole(tick)}</text
				>
			{/each}
			{#each data as d, i (d.key)}
				{@const cx = (x(d.key) ?? 0) + x.bandwidth() / 2}
				{#if d.value > 0}
					<path
						d={columnPath(cx, y(d.value), barWidth, y(0))}
						fill={color}
						opacity={active && active !== d.key ? 0.45 : 1}
					/>
				{/if}
				<!-- The hit area is the whole band, full height: aiming at a 2px sliver of a small column is not a fair ask. -->
				<rect
					x={x(d.key)}
					y={MARGIN.top}
					width={x.bandwidth()}
					height={height - MARGIN.top - MARGIN.bottom}
					fill="transparent"
					role="img"
					aria-label="{d.label}: {whole(d.value)} {unit}"
					tabindex="-1"
					onpointerenter={() => (active = d.key)}
					onpointerleave={() => (active = null)}
				/>
				{#if i % labelEvery === 0}
					<text x={cx} y={height - 6} text-anchor="middle" class="fill-muted-foreground text-[11px]"
						>{d.label}</text
					>
				{/if}
			{/each}
		</svg>
		{#if activeDatum}
			{@const cx = (x(activeDatum.key) ?? 0) + x.bandwidth() / 2}
			<div
				class="pointer-events-none absolute z-10 rounded-md border bg-popover px-2 py-1 text-xs shadow-md"
				style="left:{Math.min(width - 110, Math.max(0, cx - 50))}px; top:{Math.max(
					0,
					y(activeDatum.value) - 44
				)}px"
				role="status"
			>
				<span class="numeric font-semibold">{whole(activeDatum.value)}</span>
				<span class="text-muted-foreground">{unit} · {activeDatum.label}</span>
			</div>
		{/if}
	</div>
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
			<table class="numeric mt-2 w-full max-w-sm text-xs">
				<caption class="sr-only">{label}</caption>
				<tbody>
					{#each data as d (d.key)}
						<tr class="border-t"
							><th scope="row" class="py-1 text-left font-normal">{d.label}</th><td
								class="py-1 text-right">{whole(d.value)}</td
							></tr
						>
					{/each}
				</tbody>
			</table>
		{/if}
	</div>
</div>
