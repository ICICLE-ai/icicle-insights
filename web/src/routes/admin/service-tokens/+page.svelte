<script lang="ts">
	import { toast } from 'svelte-sonner';
	import { Copy, KeyRound, Plus } from '@lucide/svelte';
	import { Button } from '$lib/components/ui/button';
	import { Input } from '$lib/components/ui/input';
	import * as Dialog from '$lib/components/ui/dialog';
	import { Skeleton } from '$lib/components/ui/skeleton';
	import ConfirmAction from '$lib/components/admin/confirm-action.svelte';
	import Field from '$lib/components/admin/field.svelte';
	import FormSheet from '$lib/components/admin/form-sheet.svelte';
	import ResourcePicker from '$lib/components/admin/resource-picker.svelte';
	import RowActions from '$lib/components/admin/row-actions.svelte';
	import LoadError from '$lib/components/load-error.svelte';
	import { adminApi } from '$lib/admin/api';
	import type { ServiceToken, ServiceTokenMinted } from '$lib/api/types';
	import { formatDate, formatRelative } from '$lib/format';
	import { query } from '$lib/query.svelte';

	/**
	 * Webhook tokens that let a deployed ICICLE service report its own metrics, and nothing else.
	 *
	 * Each token names one resource of kind "service" inside its signature. The token string exists
	 * once, in the mint response; the server stores only its ID, so it is shown here a single time.
	 */
	const data = query(async () => {
		const [tokens, resources] = await Promise.all([adminApi.serviceTokens(), adminApi.resources()]);
		const names = new Map(resources.map((r) => [r.id?.toLowerCase() ?? '', r.name ?? '']));
		return { tokens, services: resources.filter((r) => r.type === 'service'), names };
	});

	const tokenStatus = (token: ServiceToken): 'revoked' | 'expired' | 'active' =>
		token.revokedAt
			? 'revoked'
			: token.expiresAt && Date.parse(token.expiresAt) < Date.now()
				? 'expired'
				: 'active';

	let minting = $state(false);
	let resourceID = $state('');
	let label = $state('');
	let days = $state('90');
	let minted = $state<ServiceTokenMinted | null>(null);

	let revoking = $state<ServiceToken | null>(null);
	let revokeOpen = $state(false);
	let rotateOpen = $state(false);

	async function copy(text: string) {
		try {
			await navigator.clipboard.writeText(text);
			toast.success('Copied');
		} catch {
			toast.error('Copy failed. Select the token and copy it by hand.');
		}
	}
</script>

<div class="flex flex-col gap-5">
	<div class="flex flex-wrap items-end justify-between gap-3">
		<div>
			<h1 class="text-xl font-semibold tracking-tight">Service tokens</h1>
			<p class="max-w-2xl text-sm text-muted-foreground">
				Let a deployed service post metrics for its own resource. Tokens expire; revoking one takes
				effect on the next request.
			</p>
		</div>
		<div class="flex gap-2">
			<Button variant="outline" onclick={() => (rotateOpen = true)}
				><KeyRound /> Rotate signing key</Button
			>
			<Button
				onclick={() => (
					(resourceID = data.data?.services[0]?.id ?? ''),
					(label = ''),
					(days = '90'),
					(minting = true)
				)}
				disabled={!data.data?.services.length}><Plus /> Issue token</Button
			>
		</div>
	</div>

	{#if data.error && !data.data}
		<LoadError error={data.error} retry={data.refresh} />
	{:else if !data.data}
		<Skeleton class="h-48 rounded-xl" />
	{:else}
		{#if data.data.services.length === 0}
			<p class="rounded-xl border bg-card px-4 py-3 text-sm text-muted-foreground">
				No resources of kind “service” are registered, so there is nothing to issue a token for. Add
				one under Resources first.
			</p>
		{/if}
		<div class="overflow-x-auto rounded-xl border bg-card">
			<table class="w-full min-w-[600px] text-sm">
				<caption class="sr-only">Issued service tokens</caption>
				<thead class="bg-muted/50 text-xs text-muted-foreground">
					<tr>
						<th scope="col" class="px-4 py-2 text-left font-medium">Label</th>
						<th scope="col" class="px-4 py-2 text-left font-medium">Service</th>
						<th scope="col" class="px-4 py-2 text-left font-medium">Status</th>
						<th scope="col" class="px-4 py-2 text-right font-medium">Expires</th>
						<th scope="col" class="w-10 px-2 py-2"><span class="sr-only">Actions</span></th>
					</tr>
				</thead>
				<tbody>
					{#each data.data.tokens as token (token.id)}
						{@const s = tokenStatus(token)}
						<tr class="border-t">
							<td class="px-4 py-2 font-medium">{token.label}</td>
							<td class="px-4 py-2 text-muted-foreground"
								>{data.data.names.get(token.resourceID?.toLowerCase() ?? '') ?? 'Unknown'}</td
							>
							<td class="px-4 py-2">
								<span
									class="text-xs font-medium {s === 'active'
										? 'text-gain'
										: 'text-muted-foreground'}"
								>
									{s === 'active'
										? 'Active'
										: s === 'revoked'
											? `Revoked ${formatRelative(token.revokedAt)}`
											: 'Expired'}
								</span>
							</td>
							<td
								class="px-4 py-2 text-right text-muted-foreground"
								title={formatDate(token.expiresAt)}>{formatRelative(token.expiresAt)}</td
							>
							<td class="px-2 py-1 text-right">
								<RowActions
									label={token.label ?? 'token'}
									actions={[
										{
											label: 'Revoke token',
											destructive: true,
											blockedBecause: s !== 'active' ? 'Already inactive' : null,
											onselect: () => ((revoking = token), (revokeOpen = true))
										}
									]}
								/>
							</td>
						</tr>
					{:else}
						<tr
							><td colspan="5" class="px-4 py-10 text-center text-muted-foreground"
								>No tokens issued yet.</td
							></tr
						>
					{/each}
				</tbody>
			</table>
		</div>
	{/if}
</div>

<FormSheet
	bind:open={minting}
	title="Issue service token"
	description="The token is shown once, after issuing. Store it in the service's own secret store."
	submitLabel="Issue token"
	validate={() => {
		if (!resourceID) return 'Choose the service this token reports for.';
		if (!label.trim()) return 'Enter a label that says where the token is deployed.';
		const n = Number(days);
		if (!Number.isInteger(n) || n < 1 || n > 365) return 'Lifetime must be 1 to 365 days.';
		return null;
	}}
	onsubmit={async () => {
		minted = await adminApi.mintServiceToken({
			resourceID,
			label: label.trim(),
			expiresInDays: Number(days)
		});
		data.refresh();
	}}
>
	<Field id="token-resource" label="Service">
		<ResourcePicker
			id="token-resource"
			resources={data.data?.services ?? []}
			bind:value={resourceID}
		/>
	</Field>
	<Field
		id="token-label"
		label="Deployment label"
		hint="Where the token lives, such as “prod pod” or “staging”."
	>
		<Input id="token-label" bind:value={label} autocomplete="off" />
	</Field>
	<Field id="token-days" label="Lifetime in days" hint="1 to 365. The default is 90.">
		<Input id="token-days" type="number" min="1" max="365" step="1" bind:value={days} />
	</Field>
</FormSheet>

<Dialog.Root open={!!minted} onOpenChange={(open) => !open && (minted = null)}>
	<Dialog.Content class="sm:max-w-lg">
		<Dialog.Header>
			<Dialog.Title>Token issued</Dialog.Title>
			<Dialog.Description
				>Copy it now. It can't be shown again; if it's lost, revoke it and issue another.</Dialog.Description
			>
		</Dialog.Header>
		{#if minted}
			<div class="flex flex-col gap-3 text-sm">
				<div class="flex items-start gap-2">
					<code class="flex-1 rounded-md border bg-muted px-3 py-2 font-mono text-xs break-all"
						>{minted.token}</code
					>
					<Button
						variant="outline"
						size="icon"
						onclick={() => copy(minted!.token)}
						aria-label="Copy token"><Copy /></Button
					>
				</div>
				<p class="text-muted-foreground">
					The service posts readings to <code class="font-mono text-xs">{minted.endpoint}</code>
					with
					<code class="font-mono text-xs">Authorization: Bearer &lt;token&gt;</code>.
				</p>
			</div>
		{/if}
		<Dialog.Footer><Button onclick={() => (minted = null)}>Done</Button></Dialog.Footer>
	</Dialog.Content>
</Dialog.Root>

<ConfirmAction
	bind:open={revokeOpen}
	title="Revoke “{revoking?.label}”?"
	description="The service using it starts getting 401s on its next request. This can't be undone; issue a new token to restore access."
	confirmLabel="Revoke token"
	onconfirm={async () => {
		await adminApi.revokeServiceToken(revoking!.id!);
		toast.success('Token revoked');
		data.refresh();
	}}
/>

<ConfirmAction
	bind:open={rotateOpen}
	title="Rotate the signing key?"
	description="New tokens are signed with a new key. Existing tokens keep working, because the old key stays in the keyset to verify them until they expire."
	confirmLabel="Rotate key"
	onconfirm={async () => {
		const result = await adminApi.rotateSigningKey();
		toast.success(result.message);
	}}
/>
