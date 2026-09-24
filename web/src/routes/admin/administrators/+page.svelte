<script lang="ts">
	import { toast } from 'svelte-sonner';
	import { Plus, ShieldCheck } from '@lucide/svelte';
	import { Button } from '$lib/components/ui/button';
	import { Input } from '$lib/components/ui/input';
	import { Skeleton } from '$lib/components/ui/skeleton';
	import ConfirmAction from '$lib/components/admin/confirm-action.svelte';
	import Field from '$lib/components/admin/field.svelte';
	import FormSheet from '$lib/components/admin/form-sheet.svelte';
	import RowActions from '$lib/components/admin/row-actions.svelte';
	import LoadError from '$lib/components/load-error.svelte';
	import { adminApi } from '$lib/admin/api';
	import type { Admin } from '$lib/api/types';
	import { auth } from '$lib/auth.svelte';
	import { formatDate } from '$lib/format';
	import { query } from '$lib/query.svelte';

	/**
	 * Who can change things. The root administrator comes from the deployment's environment and is
	 * an admin whatever this list says, so an accidental removal can always be undone by them.
	 */
	const data = query(() => adminApi.admins());

	let adding = $state(false);
	let username = $state('');
	let removing = $state<Admin | null>(null);
	let confirmOpen = $state(false);
</script>

<div class="flex flex-col gap-5">
	<div class="flex flex-wrap items-end justify-between gap-3">
		<div>
			<h1 class="text-xl font-semibold tracking-tight">Administrators</h1>
			<p class="text-sm text-muted-foreground">
				Tapis users who can manage the catalog, credentials and tokens.
			</p>
		</div>
		<Button onclick={() => ((username = ''), (adding = true))}><Plus /> Add administrator</Button>
	</div>

	{#if data.error && !data.data}
		<LoadError error={data.error} retry={data.refresh} />
	{:else if !data.data}
		<Skeleton class="h-40 rounded-xl" />
	{:else}
		<div class="overflow-x-auto rounded-xl border bg-card">
			<table class="w-full min-w-[480px] text-sm">
				<caption class="sr-only">Administrators</caption>
				<thead class="bg-muted/50 text-xs text-muted-foreground">
					<tr>
						<th scope="col" class="px-4 py-2 text-left font-medium">Username</th>
						<th scope="col" class="px-4 py-2 text-left font-medium">Added by</th>
						<th scope="col" class="px-4 py-2 text-right font-medium">Since</th>
						<th scope="col" class="w-10 px-2 py-2"><span class="sr-only">Actions</span></th>
					</tr>
				</thead>
				<tbody>
					{#each data.data as admin (admin.id ?? admin.username)}
						<tr class="border-t">
							<td class="px-4 py-2 font-medium">
								<span class="flex items-center gap-2">
									{admin.username}
									{#if admin.isRoot}<span
											class="inline-flex items-center gap-1 text-xs font-normal text-muted-foreground"
											><ShieldCheck class="size-3.5" />Root</span
										>{/if}
									{#if admin.username === auth.claims.username}<span
											class="text-xs font-normal text-muted-foreground">(you)</span
										>{/if}
								</span>
							</td>
							<td class="px-4 py-2 text-muted-foreground"
								>{admin.isRoot ? 'Deployment environment' : admin.addedBy}</td
							>
							<td class="px-4 py-2 text-right text-muted-foreground"
								>{admin.isRoot ? '—' : formatDate(admin.createdAt)}</td
							>
							<td class="px-2 py-1 text-right">
								<RowActions
									label={admin.username ?? 'administrator'}
									actions={[
										{
											label: 'Remove access',
											destructive: true,
											blockedBecause: admin.isRoot ? 'Set by ROOT_ADMIN_USERNAME' : null,
											onselect: () => ((removing = admin), (confirmOpen = true))
										}
									]}
								/>
							</td>
						</tr>
					{/each}
				</tbody>
			</table>
		</div>
	{/if}
</div>

<FormSheet
	bind:open={adding}
	title="Add administrator"
	description="Their Tapis username on this deployment's tenant. Access applies from their next request."
	submitLabel="Add administrator"
	validate={() => (username.trim() ? null : 'Enter a Tapis username.')}
	onsubmit={async () => {
		await adminApi.addAdmin(username.trim());
		toast.success(`${username.trim()} is now an administrator`);
		data.refresh();
	}}
>
	<Field id="admin-username" label="Tapis username">
		<Input id="admin-username" bind:value={username} autocomplete="off" spellcheck={false} />
	</Field>
</FormSheet>

<ConfirmAction
	bind:open={confirmOpen}
	title="Remove {removing?.username}?"
	description={removing?.username === auth.claims.username
		? 'That is you. You lose admin access as soon as this completes.'
		: 'They keep their Tapis account but lose admin access on their next request.'}
	confirmLabel="Remove access"
	onconfirm={async () => {
		await adminApi.removeAdmin(removing!.id!);
		toast.success(`Removed ${removing?.username}`);
		data.refresh();
	}}
/>
