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
	import RowActions from '$lib/components/admin/row-actions.svelte';
	import LoadError from '$lib/components/load-error.svelte';
	import PlatformDot from '$lib/components/platform-dot.svelte';
	import { adminApi } from '$lib/admin/api';
	import type { Account, Platform } from '$lib/api/types';
	import { formatDate, PLATFORM_ORDER, platformLabel, pluralize, whole } from '$lib/format';
	import { query } from '$lib/query.svelte';

	/**
	 * Platform accounts: the owners every resource and credential hangs off.
	 *
	 * Deleting is only offered once an account has no resources and no vault, mirroring the
	 * server's rule. A soft-deleted account with live resources would break the collection sweep,
	 * which eager-loads each resource's account.
	 */
	const data = query(async () => {
		const [accounts, resources, vaults] = await Promise.all([
			adminApi.accounts(),
			adminApi.resources(),
			adminApi.vaults()
		]);
		const resourceCount = new Map<string, number>();
		for (const r of resources) {
			const key = r.accountID?.toLowerCase() ?? '';
			resourceCount.set(key, (resourceCount.get(key) ?? 0) + 1);
		}
		const hasVault = new Set(vaults.map((v) => v.accountID?.toLowerCase() ?? ''));
		return { accounts, resourceCount, hasVault };
	});

	let creating = $state(false);
	let name = $state('');
	let platform = $state<Platform>('github');

	let deleting = $state<Account | null>(null);
	let confirmOpen = $state(false);

	const blockedReason = (account: Account): string | null => {
		const id = account.id?.toLowerCase() ?? '';
		const count = data.data?.resourceCount.get(id) ?? 0;
		if (count > 0) return `Delete its ${pluralize(count, 'resource')} first`;
		if (data.data?.hasVault.has(id)) return 'Delete its vault credential first';
		return null;
	};
</script>

<div class="flex flex-col gap-5">
	<div class="flex flex-wrap items-end justify-between gap-3">
		<div>
			<h1 class="text-xl font-semibold tracking-tight">Accounts</h1>
			<p class="text-sm text-muted-foreground">
				One per organisation or user on each platform. Resources and credentials belong to an
				account.
			</p>
		</div>
		<Button onclick={() => ((name = ''), (platform = 'github'), (creating = true))}
			><Plus /> Add account</Button
		>
	</div>

	{#if data.error && !data.data}
		<LoadError error={data.error} retry={data.refresh} />
	{:else if !data.data}
		<Skeleton class="h-64 rounded-xl" />
	{:else}
		<div class="overflow-x-auto rounded-xl border bg-card">
			<table class="w-full min-w-[560px] text-sm">
				<caption class="sr-only">Platform accounts</caption>
				<thead class="bg-muted/50 text-xs text-muted-foreground">
					<tr>
						<th scope="col" class="px-4 py-2 text-left font-medium">Account</th>
						<th scope="col" class="px-4 py-2 text-left font-medium">Platform</th>
						<th scope="col" class="px-4 py-2 text-right font-medium">Resources</th>
						<th scope="col" class="px-4 py-2 text-left font-medium">Credential</th>
						<th scope="col" class="px-4 py-2 text-left font-medium">Added</th>
						<th scope="col" class="w-10 px-2 py-2"><span class="sr-only">Actions</span></th>
					</tr>
				</thead>
				<tbody>
					{#each data.data.accounts as account (account.id)}
						{@const id = account.id?.toLowerCase() ?? ''}
						<tr class="border-t">
							<td class="px-4 py-2 font-medium">{account.name}</td>
							<td class="px-4 py-2"><PlatformDot platform={account.platform} /></td>
							<td class="numeric px-4 py-2 text-right"
								>{whole(data.data.resourceCount.get(id) ?? 0)}</td
							>
							<td class="px-4 py-2 text-muted-foreground"
								>{data.data.hasVault.has(id) ? 'Stored in vault' : '—'}</td
							>
							<td class="px-4 py-2 text-muted-foreground">{formatDate(account.createdAt)}</td>
							<td class="px-2 py-1 text-right">
								<RowActions
									label={account.name ?? 'account'}
									actions={[
										{
											label: 'Delete account',
											destructive: true,
											blockedBecause: blockedReason(account),
											onselect: () => ((deleting = account), (confirmOpen = true))
										}
									]}
								/>
							</td>
						</tr>
					{:else}
						<tr
							><td colspan="6" class="px-4 py-10 text-center text-muted-foreground"
								>No accounts yet. Add one to start registering resources.</td
							></tr
						>
					{/each}
				</tbody>
			</table>
		</div>
	{/if}
</div>

<FormSheet
	bind:open={creating}
	title="Add account"
	description="The name exactly as the platform spells it: the GitHub organisation or the Hugging Face user."
	submitLabel="Add account"
	validate={() => (name.trim() ? null : 'Enter the account name.')}
	onsubmit={async () => {
		await adminApi.createAccount({ name: name.trim(), platform });
		toast.success(`Added ${name.trim()} on ${platformLabel(platform)}`);
		data.refresh();
	}}
>
	<Field id="account-platform" label="Platform">
		<Select.Root type="single" bind:value={platform}>
			<Select.Trigger id="account-platform" class="w-full">{platformLabel(platform)}</Select.Trigger
			>
			<Select.Content>
				{#each PLATFORM_ORDER as p (p)}<Select.Item value={p} label={platformLabel(p)} />{/each}
			</Select.Content>
		</Select.Root>
	</Field>
	<Field id="account-name" label="Name">
		<Input id="account-name" bind:value={name} placeholder="icicle-ai" autocomplete="off" />
	</Field>
</FormSheet>

<ConfirmAction
	bind:open={confirmOpen}
	title="Delete {deleting?.name}?"
	description="The account is removed from the catalog. Collected history for its former resources stays in the database."
	confirmLabel="Delete account"
	onconfirm={async () => {
		await adminApi.deleteAccount(deleting!.id!);
		toast.success(`Deleted ${deleting?.name}`);
		data.refresh();
	}}
/>
