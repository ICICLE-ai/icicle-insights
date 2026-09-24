<script lang="ts">
	import { page } from '$app/state';
	import {
		Activity,
		Building2,
		Boxes,
		KeyRound,
		LogOut,
		Ruler,
		ShieldCheck,
		Tag,
		Ticket,
		Users
	} from '@lucide/svelte';
	import { Button } from '$lib/components/ui/button';
	import { Textarea } from '$lib/components/ui/textarea';
	import { Skeleton } from '$lib/components/ui/skeleton';
	import LoadError from '$lib/components/load-error.svelte';
	import { auth } from '$lib/auth.svelte';
	import { session } from '$lib/admin/session.svelte';
	import { formatRelative } from '$lib/format';

	/**
	 * The admin console's frame: a sign-in gate, then a sidebar of sections.
	 *
	 * The gate asks the server, not the token, whether its holder is an administrator — see
	 * `session.svelte.ts`. Public pages never pass through here, so a signed-out visitor loses
	 * nothing.
	 */
	let { children } = $props();

	let pasted = $state('');

	$effect(() => {
		// Re-verify whenever the token changes: pasted here, set by the parent frame, or cleared.
		void auth.token;
		session.verify();
	});

	const NAV = [
		{ href: '/admin', label: 'Operations', icon: Activity },
		{ href: '/admin/accounts', label: 'Accounts', icon: Building2 },
		{ href: '/admin/resources', label: 'Resources', icon: Boxes },
		{ href: '/admin/releases', label: 'Releases', icon: Tag },
		{ href: '/admin/metrics', label: 'Metrics', icon: Ruler },
		{ href: '/admin/vaults', label: 'Vaults', icon: KeyRound },
		{ href: '/admin/service-tokens', label: 'Service tokens', icon: Ticket },
		{ href: '/admin/administrators', label: 'Administrators', icon: Users }
	];

	const isActive = (href: string) =>
		href === '/admin' ? page.url.pathname === '/admin' : page.url.pathname.startsWith(href);

	const expiresAt = $derived(auth.claims.expiresAt);
</script>

<svelte:head><title>Administration · ICICLE Insights</title></svelte:head>

{#if session.state.status === 'admin'}
	<div class="grid gap-6 md:grid-cols-[13rem_1fr]">
		<aside class="flex flex-col gap-4">
			<nav aria-label="Administration" class="flex gap-1 overflow-x-auto md:flex-col">
				{#each NAV as item (item.href)}
					<a
						href={item.href}
						aria-current={isActive(item.href) ? 'page' : undefined}
						class="flex items-center gap-2 rounded-lg px-2.5 py-1.5 text-sm whitespace-nowrap transition-colors {isActive(
							item.href
						)
							? 'bg-muted font-medium text-foreground'
							: 'text-muted-foreground hover:bg-muted/60 hover:text-foreground'}"
					>
						<item.icon class="size-4" />
						{item.label}
					</a>
				{/each}
			</nav>
			<div class="hidden border-t pt-3 text-xs text-muted-foreground md:block">
				<p class="flex items-center gap-1.5 font-medium text-foreground">
					<ShieldCheck class="size-3.5" />
					{auth.claims.username ?? 'Administrator'}
				</p>
				{#if expiresAt}
					<p class={expiresAt.getTime() - Date.now() < 15 * 60_000 ? 'text-loss' : ''}>
						Token expires {formatRelative(expiresAt)}
					</p>
				{/if}
				<button
					type="button"
					class="mt-2 inline-flex items-center gap-1 hover:text-foreground"
					onclick={() => session.signOut()}
				>
					<LogOut class="size-3" /> Sign out
				</button>
			</div>
		</aside>
		<div class="min-w-0">{@render children()}</div>
	</div>
{:else}
	<div class="mx-auto flex max-w-lg flex-col gap-5 py-6">
		<div>
			<h1 class="text-xl font-semibold tracking-tight">Administration</h1>
			<p class="text-sm text-muted-foreground">
				Sign in with a Tapis token for this deployment's tenant. Opened from TapisUI, the dashboard
				receives it automatically; otherwise paste one below. It is held in memory only and
				forgotten on reload.
			</p>
		</div>

		{#if session.state.status === 'checking'}
			<Skeleton class="h-24 rounded-xl" />
		{:else}
			{#if session.state.status === 'unverified' || session.state.status === 'forbidden'}
				<p
					role="alert"
					class="rounded-lg border border-loss/30 bg-loss/5 px-3 py-2 text-sm text-loss"
				>
					{session.state.reason}
				</p>
			{:else if session.state.status === 'error'}
				<LoadError error={session.state.error} retry={() => session.verify()} />
			{/if}

			<form
				class="flex flex-col gap-3"
				onsubmit={(event) => {
					event.preventDefault();
					if (pasted.trim()) auth.set(pasted, 'manual');
					pasted = '';
				}}
			>
				<label for="token" class="text-sm font-medium">Tapis token</label>
				<Textarea
					id="token"
					bind:value={pasted}
					rows={4}
					autocomplete="off"
					spellcheck={false}
					placeholder="eyJhbGciOi…"
					class="font-mono text-xs"
				/>
				<div class="flex gap-2">
					<Button type="submit" disabled={!pasted.trim()}>Sign in</Button>
					{#if auth.token}
						<Button type="button" variant="outline" onclick={() => session.signOut()}
							>Clear token</Button
						>
					{/if}
				</div>
			</form>
		{/if}
	</div>
{/if}
