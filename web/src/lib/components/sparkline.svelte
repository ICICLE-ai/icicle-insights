<script lang="ts">
	import type { Point } from '$lib/data/types';

	/**
	 * A trend at a glance: one thin line in the de-emphasis ink, with the newest value marked.
	 *
	 * No axes and no tooltip — a sparkline answers "up, down or flat" beside a number that already
	 * states the value. Anything more precise belongs in the main chart or its table view.
	 */
	let {
		points,
		width = 120,
		height = 28,
		label
	}: { points: readonly Point[]; width?: number; height?: number; label: string } = $props();

	const PAD = 3;

	const path = $derived.by(() => {
		if (points.length < 2) return null;
		const values = points.map((p) => p.v);
		const min = Math.min(...values);
		const max = Math.max(...values);
		const span = max - min || 1;
		const coords = points.map((p, i) => [
			PAD + (i / (points.length - 1)) * (width - PAD * 2),
			// A flat series sits mid-height rather than on the floor, so "no change" reads as level.
			max === min ? height / 2 : height - PAD - ((p.v - min) / span) * (height - PAD * 2)
		]);
		return {
			d: coords.map(([x, y], i) => `${i ? 'L' : 'M'}${x.toFixed(1)},${y.toFixed(1)}`).join(''),
			end: coords[coords.length - 1]
		};
	});
</script>

{#if path}
	<svg
		{width}
		{height}
		viewBox="0 0 {width} {height}"
		role="img"
		aria-label={label}
		class="block overflow-visible"
	>
		<path
			d={path.d}
			fill="none"
			stroke="var(--muted-foreground)"
			stroke-width="1.5"
			stroke-linejoin="round"
			stroke-linecap="round"
		/>
		<circle
			cx={path.end[0]}
			cy={path.end[1]}
			r="2.5"
			fill="var(--foreground)"
			stroke="var(--card)"
			stroke-width="1.5"
		/>
	</svg>
{:else}
	<div style="width:{width}px;height:{height}px" aria-hidden="true"></div>
{/if}
