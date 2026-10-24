<script lang="ts">
	import type { HTMLAttributes } from 'svelte/elements';
	import { cn } from '$lib/utils';

	/** Keep growing tables inside a named, keyboard-scrollable region. */
	let {
		label,
		class: className,
		children,
		...rest
	}: HTMLAttributes<HTMLDivElement> & { label: string } = $props();
</script>

<!-- A focusable scroll region lets keyboard users reach every row and column. -->
<!-- svelte-ignore a11y_no_noninteractive_tabindex -->
<div
	role="region"
	aria-label={label}
	tabindex="0"
	class={cn(
		'relative max-h-[min(32rem,65dvh)] w-full max-w-full min-w-0 overflow-auto rounded-lg border [overflow-wrap:normal] outline-none focus-visible:ring-3 focus-visible:ring-ring/50 [&_th]:whitespace-nowrap [&_thead]:sticky [&_thead]:top-0 [&_thead]:z-10 [&_thead]:bg-muted',
		className
	)}
	{...rest}
>
	{@render children?.()}
</div>
