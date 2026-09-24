<script lang="ts">
	import { toast } from 'svelte-sonner';
	import { CircleAlert, Plus, TriangleAlert } from '@lucide/svelte';
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
	import { adminApi, type ExpirationDate } from '$lib/admin/api';
	import type { Vault } from '$lib/api/types';
	import { formatDate, formatRelative } from '$lib/format';
	import { query } from '$lib/query.svelte';

	/**
	 * Platform credentials. The token itself goes straight to the Tapis vault; this database keeps
	 * only the secret's name and the expiry you enter, which is what the warnings here are based on.
	 * A token never comes back out through the API, so rotating means pasting a new one.
	 */
	const data = query(async () => {
		const [vaults, accounts] = await Promise.all([adminApi.vaults(), adminApi.accounts()]);
		const accountByID = new Map(accounts.map((a) => [a.id?.toLowerCase() ?? '', a]));
		const withVault = new Set(vaults.map((v) => v.accountID?.toLowerCase() ?? ''));
		return {
			vaults,
			accounts,
			accountByID,
			withoutVault: accounts.filter((a) => !withVault.has(a.id?.toLowerCase() ?? ''))
		};
	});

	const SOON = 14 * 86_400_000;
	const status = (vault: Vault) => {
		if (!vault.expiresAt) return null;
		const left = Date.parse(vault.expiresAt) - Date.now();
		return left < 0 ? 'expired' : left < SOON ? 'soon' : null;
	};

	let sheetOpen = $state(false);
	let rotating = $state<Vault | null>(null);
	let accountID = $state('');
	let token = $state('');
	let expires = $state('');

	const toExpiration = (value: string): ExpirationDate => {
		const [year, month, day] = value.split('-').map(Number);
		return { year, month, day };
	};

	function openCreate() {
		rotating = null;
		accountID = data.data?.withoutVault[0]?.id ?? '';
		token = '';
		expires = '';
		sheetOpen = true;
	}

	function openRotate(vault: Vault) {
		rotating = vault;
		token = '';
		expires = '';
		sheetOpen = true;
	}

	let deleting = $state<Vault | null>(null);
	let confirmOpen = $state(false);
	const accountName = (vault: Vault | null) =>
		data.data?.accountByID.get(vault?.accountID?.toLowerCase() ?? '')?.name ?? 'this account';
</script>

<div class="flex flex-col gap-5">
	<div class="flex flex-wrap items-end justify-between gap-3">
		<div>
			<h1 class="text-xl font-semibold tracking-tight">Vaults</h1>
			<p class="max-w-2xl text-sm text-muted-foreground">
				One platform token per account, stored in Tapis Vault. Collection for an account stops when
				its token expires.
			</p>
		</div>
		<Button onclick={openCreate} disabled={!data.data?.withoutVault.length}
			><Plus /> Add credential</Button
		>
	</div>

	{#if data.error && !data.data}
		<LoadError error={data.error} retry={data.refresh} />
	{:else if !data.data}
		<Skeleton class="h-48 rounded-xl" />
	{:else}
		<div class="overflow-x-auto rounded-xl border bg-card">
			<table class="w-full min-w-[560px] text-sm">
				<caption class="sr-only">Stored platform credentials</caption>
				<thead class="bg-muted/50 text-xs text-muted-foreground">
					<tr>
						<th scope="col" class="px-4 py-2 text-left font-medium">Account</th>
						<th scope="col" class="px-4 py-2 text-left font-medium">Secret name</th>
						<th scope="col" class="px-4 py-2 text-left font-medium">Expires</th>
						<th scope="col" class="w-10 px-2 py-2"><span class="sr-only">Actions</span></th>
					</tr>
				</thead>
				<tbody>
					{#each data.data.vaults as vault (vault.id)}
						{@const owner = data.data.accountByID.get(vault.accountID?.toLowerCase() ?? '')}
						{@const expiry = status(vault)}
						<tr class="border-t">
							<td class="px-4 py-2"
								><span class="flex items-center gap-2 font-medium"
									>{owner?.name}<span class="font-normal text-muted-foreground"
										><PlatformDot platform={owner?.platform} /></span
									></span
								></td
							>
							<td class="px-4 py-2 font-mono text-xs text-muted-foreground">{vault.name}</td>
							<td class="px-4 py-2">
								<span
									class="flex items-center gap-1.5 {expiry === 'expired'
										? 'text-loss'
										: expiry === 'soon'
											? 'text-amber-700 dark:text-amber-400'
											: ''}"
								>
									{#if expiry === 'expired'}<CircleAlert class="size-3.5" />Expired {formatRelative(
											vault.expiresAt
										)}
									{:else if expiry === 'soon'}<TriangleAlert class="size-3.5" />{formatDate(
											vault.expiresAt
										)} · {formatRelative(vault.expiresAt)}
									{:else}{formatDate(vault.expiresAt)}{/if}
								</span>
							</td>
							<td class="px-2 py-1 text-right">
								<RowActions
									label="credential for {owner?.name}"
									actions={[
										{ label: 'Replace token', onselect: () => openRotate(vault) },
										{
											label: 'Delete credential',
											destructive: true,
											onselect: () => ((deleting = vault), (confirmOpen = true))
										}
									]}
								/>
							</td>
						</tr>
					{:else}
						<tr
							><td colspan="4" class="px-4 py-10 text-center text-muted-foreground"
								>No credentials stored. Nothing can be collected until each account has one.</td
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
	title={rotating ? `Replace token for ${accountName(rotating)}` : 'Add credential'}
	description="The token is written to Tapis Vault and never shown again. Use a read-only token scoped to what collection needs."
	submitLabel={rotating ? 'Replace token' : 'Store credential'}
	validate={() => {
		if (!rotating && !accountID) return 'Choose the account this token is for.';
		if (!token.trim()) return 'Paste the platform token.';
		if (!expires)
			return 'Enter the date the token expires, so the console can warn before it does.';
		return null;
	}}
	onsubmit={async () => {
		const body = { token: token.trim(), expires: toExpiration(expires) };
		if (rotating) await adminApi.rotateVault(rotating.id!, body);
		else await adminApi.createVault({ ...body, accountID });
		token = '';
		toast.success(rotating ? 'Token replaced' : 'Credential stored');
		data.refresh();
	}}
>
	{#if !rotating}
		<Field id="vault-account" label="Account" hint="Only accounts without a credential are listed.">
			<Select.Root type="single" bind:value={accountID}>
				<Select.Trigger id="vault-account" class="w-full"
					>{data.data?.accountByID.get(accountID.toLowerCase())?.name ??
						'Choose an account'}</Select.Trigger
				>
				<Select.Content>
					{#each data.data?.withoutVault ?? [] as a (a.id)}<Select.Item
							value={a.id!}
							label="{a.name} · {a.platform}"
						/>{/each}
				</Select.Content>
			</Select.Root>
		</Field>
	{/if}
	<Field id="vault-token" label="Token">
		<Input
			id="vault-token"
			type="password"
			bind:value={token}
			autocomplete="off"
			spellcheck={false}
			class="font-mono"
		/>
	</Field>
	<Field id="vault-expires" label="Expires on">
		<Input id="vault-expires" type="date" bind:value={expires} />
	</Field>
</FormSheet>

<ConfirmAction
	bind:open={confirmOpen}
	title="Delete the credential for {accountName(deleting)}?"
	description="Every version of the secret is destroyed in Tapis Vault, and collection for this account stops until a new token is stored."
	confirmLabel="Delete credential"
	onconfirm={async () => {
		await adminApi.deleteVault(deleting!.id!);
		toast.success('Credential deleted');
		data.refresh();
	}}
/>
