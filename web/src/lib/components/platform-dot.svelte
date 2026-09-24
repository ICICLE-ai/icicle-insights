<script lang="ts">
	import { platformColor, platformLabel } from '$lib/format';

	/** A platform's name with its fixed series colour beside it — identity never rests on colour. */
	let { platform }: { platform: string | null | undefined } = $props();
</script>

<span class="inline-flex items-center gap-1.5">
	<span
		class="inline-block size-2 shrink-0 rounded-full"
		style="background:{platformColor(platform)}"
		aria-hidden="true"
	></span>
	<span>{platformLabel(platform)}</span>
</span>
