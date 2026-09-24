<script lang="ts">
	import { page } from '$app/state';
	import { Moon, Sun, ShieldCheck } from '@lucide/svelte';
	import { mode, toggleMode } from 'mode-watcher';
	import { Button } from '$lib/components/ui/button';
	import RangePicker from './range-picker.svelte';
	import ScopePicker from './scope-picker.svelte';
	import { auth } from '$lib/auth.svelte';
	import type { Catalog } from '$lib/data/catalog';
	import { withScope } from '$lib/scope.svelte';

	/**
	 * The one filter row plus navigation. Filters sit above everything they scope and apply to every
	 * page, so switching from Overview to Resources keeps what you were looking at.
	 */
	let { catalog }: { catalog: Catalog | null } = $props();

	const NAV = [
		{ href: '/', label: 'Overview' },
		{ href: '/resources', label: 'Resources' },
		{ href: '/releases', label: 'Releases' },
		{ href: '/provenance', label: 'Provenance' }
	];

	const isActive = (href: string) =>
		href === '/' ? page.url.pathname === '/' : page.url.pathname.startsWith(href);

	const inAdmin = $derived(page.url.pathname.startsWith('/admin'));
</script>

<header class="sticky top-0 z-30 border-b bg-background/85 backdrop-blur">
	<div class="mx-auto flex max-w-7xl flex-wrap items-center gap-x-3 gap-y-2 px-4 pt-3 sm:px-6">
		<a href={withScope('/')} class="mr-2 flex items-center gap-2 font-semibold tracking-tight">
			<img src="/logo-mark.svg" alt="" class="size-6 dark:invert" />
			<span>ICICLE Insights</span>
		</a>
		{#if !inAdmin}
			<div class="order-last flex w-full items-center gap-2 sm:order-none sm:w-auto sm:flex-1">
				<ScopePicker {catalog} />
				<RangePicker />
			</div>
		{:else}
			<div class="flex-1"></div>
		{/if}
		<div class="ml-auto flex items-center gap-1 sm:ml-0">
			<Button
				variant="ghost"
				size="icon"
				onclick={toggleMode}
				aria-label="Switch to {mode.current === 'dark' ? 'light' : 'dark'} theme"
			>
				{#if mode.current === 'dark'}<Sun />{:else}<Moon />{/if}
			</Button>
			<Button variant={inAdmin ? 'secondary' : 'ghost'} size="sm" href="/admin">
				<ShieldCheck />
				{auth.claims.username ?? 'Admin'}
			</Button>
		</div>
	</div>
	<nav
		class="mx-auto flex max-w-7xl gap-5 overflow-x-auto px-4 text-sm sm:px-6"
		aria-label="Sections"
	>
		{#if inAdmin}
			<a
				href="/"
				class="border-b-2 border-transparent py-2.5 text-muted-foreground hover:text-foreground"
				>← Public dashboard</a
			>
		{:else}
			{#each NAV as item (item.href)}
				<a
					href={withScope(item.href)}
					aria-current={isActive(item.href) ? 'page' : undefined}
					class="border-b-2 py-2.5 whitespace-nowrap transition-colors {isActive(item.href)
						? 'border-foreground font-medium text-foreground'
						: 'border-transparent text-muted-foreground hover:text-foreground'}"
				>
					{item.label}
				</a>
			{/each}
		{/if}
	</nav>
</header>
