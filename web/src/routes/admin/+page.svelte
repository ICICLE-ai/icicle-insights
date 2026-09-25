<script lang="ts">
	import { CircleAlert, CircleCheck, TriangleAlert, RefreshCw } from '@lucide/svelte';
	import * as Card from '$lib/components/ui/card';
	import { Button } from '$lib/components/ui/button';
	import { Skeleton } from '$lib/components/ui/skeleton';
	import LoadError from '$lib/components/load-error.svelte';
	import { adminApi } from '$lib/admin/api';
	import { formatDate, formatRelative, metricLabel, whole } from '$lib/format';
	import { query } from '$lib/query.svelte';

	/**
	 * Is collection healthy? The queue and the scheduler's heartbeat say whether work is flowing;
	 * the failure log says what broke; watermarks say how far each rolling metric has been counted.
	 *
	 * Status always pairs its colour with an icon and a word, so it never rests on colour alone.
	 */
	const data = query(async () => {
		const [queue, failures, watermarks] = await Promise.all([
			adminApi.queues(),
			adminApi.failures(50),
			adminApi.watermarks()
		]);
		return { queue, failures, watermarks };
	});

	// The four states `AdminInsightController` reports. "Not observed" is not a fault on a fresh
	// deployment — the heartbeat is written by the scheduler's first run — so it reads as a warning.
	const SCHEDULER: Record<string, { label: string; tone: 'good' | 'warn' | 'bad' }> = {
		healthy: { label: 'Healthy', tone: 'good' },
		stale: { label: 'Stale — no recent heartbeat', tone: 'bad' },
		notObserved: { label: 'Not seen yet', tone: 'warn' },
		unavailable: { label: 'Valkey unreachable', tone: 'bad' }
	};
	const scheduler = $derived(
		SCHEDULER[data.data?.queue.schedulerState ?? ''] ?? {
			label: data.data?.queue.schedulerState ?? '',
			tone: 'warn'
		}
	);
	let expanded = $state<string | null>(null);
</script>

<div class="flex flex-col gap-6">
	<div class="flex items-end justify-between gap-2">
		<div>
			<h1 class="text-xl font-semibold tracking-tight">Operations</h1>
			<p class="text-sm text-muted-foreground">
				Queue health, recent failures and collection progress.
			</p>
		</div>
		<Button variant="outline" size="sm" onclick={data.refresh} disabled={data.loading}>
			<RefreshCw class={data.loading ? 'animate-spin' : ''} /> Refresh
		</Button>
	</div>

	{#if data.error && !data.data}
		<LoadError error={data.error} retry={data.refresh} />
	{:else if !data.data}
		<Skeleton class="h-28 rounded-xl" />
		<Skeleton class="h-64 rounded-xl" />
	{:else}
		{@const { queue, failures, watermarks } = data.data}
		<section class="grid gap-3 sm:grid-cols-3" aria-label="Queue">
			<div class="flex flex-col gap-1 rounded-xl border bg-card p-4">
				<span class="text-xs text-muted-foreground">Waiting on “{queue.queue}”</span>
				<span class="text-2xl font-semibold">{whole(queue.pending)}</span>
			</div>
			<div class="flex flex-col gap-1 rounded-xl border bg-card p-4">
				<span class="text-xs text-muted-foreground">In progress</span>
				<span class="text-2xl font-semibold">{whole(queue.processing)}</span>
			</div>
			<div class="flex flex-col gap-1 rounded-xl border bg-card p-4">
				<span class="text-xs text-muted-foreground">Scheduler</span>
				<span
					class="flex items-center gap-1.5 text-sm font-medium {scheduler.tone === 'good'
						? 'text-gain'
						: scheduler.tone === 'bad'
							? 'text-loss'
							: 'text-amber-700 dark:text-amber-400'}"
				>
					{#if scheduler.tone === 'good'}<CircleCheck
							class="size-4"
						/>{:else if scheduler.tone === 'bad'}<CircleAlert class="size-4" />{:else}<TriangleAlert
							class="size-4"
						/>{/if}
					<span>{scheduler.label}</span>
				</span>
				<span class="text-xs text-muted-foreground">
					{queue.schedulerLastSeenAt
						? `Last seen ${formatRelative(queue.schedulerLastSeenAt)}`
						: 'No heartbeat recorded'}
				</span>
			</div>
		</section>

		<Card.Root>
			<Card.Header>
				<Card.Title>Recent failures</Card.Title>
				<Card.Description>
					Collections and backups that exhausted their retries, newest first. Critical ones need a
					person, usually a token.
				</Card.Description>
			</Card.Header>
			<Card.Content>
				{#if failures.length === 0}
					<p class="flex items-center gap-2 text-sm text-muted-foreground">
						<CircleCheck class="size-4 text-gain" /> No failures recorded.
					</p>
				{:else}
					<div class="overflow-x-auto rounded-lg border">
						<table class="w-full min-w-[640px] text-sm">
							<caption class="sr-only">Recent job failures</caption>
							<thead class="bg-muted/50 text-xs text-muted-foreground">
								<tr>
									<th scope="col" class="px-3 py-2 text-left font-medium">Severity</th>
									<th scope="col" class="px-3 py-2 text-left font-medium">Subject</th>
									<th scope="col" class="px-3 py-2 text-left font-medium">Job</th>
									<th scope="col" class="px-3 py-2 text-left font-medium">Cause</th>
									<th scope="col" class="px-3 py-2 text-right font-medium">When</th>
								</tr>
							</thead>
							<tbody>
								{#each failures as failure (failure.id ?? failure.failedAt + failure.subject)}
									{@const key = failure.id ?? failure.failedAt + failure.subject}
									<tr class="border-t align-top">
										<td class="px-3 py-2 whitespace-nowrap">
											<span
												class="inline-flex items-center gap-1 text-xs font-medium {failure.severity ===
												'critical'
													? 'text-loss'
													: 'text-amber-700 dark:text-amber-400'}"
											>
												{#if failure.severity === 'critical'}<CircleAlert
														class="size-3.5"
													/>{:else}<TriangleAlert class="size-3.5" />{/if}
												{failure.severity}
											</span>
										</td>
										<td class="px-3 py-2 font-medium">{failure.subject}</td>
										<td class="px-3 py-2 text-muted-foreground">{failure.job}</td>
										<td class="px-3 py-2">
											<button
												type="button"
												class="text-left font-mono text-xs hover:underline"
												aria-expanded={expanded === key}
												onclick={() => (expanded = expanded === key ? null : key)}
											>
												{failure.identifier}
											</button>
											{#if expanded === key}
												<p
													class="mt-1 max-w-prose text-xs whitespace-pre-line text-muted-foreground"
												>
													{failure.details}
												</p>
											{/if}
										</td>
										<td
											class="px-3 py-2 text-right text-xs whitespace-nowrap text-muted-foreground"
											title={formatDate(failure.failedAt)}>{formatRelative(failure.failedAt)}</td
										>
									</tr>
								{/each}
							</tbody>
						</table>
					</div>
				{/if}
			</Card.Content>
		</Card.Root>

		<Card.Root>
			<Card.Header>
				<Card.Title>Watermarks</Card.Title>
				<Card.Description
					>How far each rolling metric has been folded into its all-time total. Days after this are
					not yet counted.</Card.Description
				>
			</Card.Header>
			<Card.Content>
				{#if watermarks.length === 0}
					<p class="text-sm text-muted-foreground">No rolling metrics have been counted yet.</p>
				{:else}
					<div class="max-h-96 overflow-auto rounded-lg border">
						<table class="w-full text-sm">
							<caption class="sr-only">Watermarks per resource and metric</caption>
							<thead class="sticky top-0 bg-muted text-xs text-muted-foreground">
								<tr>
									<th scope="col" class="px-3 py-2 text-left font-medium">Resource</th>
									<th scope="col" class="px-3 py-2 text-left font-medium">Metric</th>
									<th scope="col" class="px-3 py-2 text-right font-medium">Counted through</th>
								</tr>
							</thead>
							<tbody>
								{#each [...watermarks].sort( (a, b) => a.countedThrough.localeCompare(b.countedThrough) ) as mark (mark.id ?? mark.resourceID + mark.type)}
									<tr class="border-t">
										<td class="px-3 py-1.5">{mark.resourceName}</td>
										<td class="px-3 py-1.5 text-muted-foreground">{metricLabel(mark.type)}</td>
										<td class="px-3 py-1.5 text-right">{formatDate(mark.countedThrough)}</td>
									</tr>
								{/each}
							</tbody>
						</table>
					</div>
				{/if}
			</Card.Content>
		</Card.Root>
	{/if}
</div>
