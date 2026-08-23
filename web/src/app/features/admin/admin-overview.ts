import { Component, computed, inject, signal } from '@angular/core';

import { SessionStore } from '../../core/auth/session-store';
import { TokenStore } from '../../core/auth/token-store';
import { ExperimentStore } from '../../core/layout/experiment-store';
import { ErrorNotice } from '../../shared/ui/error-notice';
import { Paginator, pageSlice } from '../../shared/ui/paginator';
import { AdminStore } from './admin-store';
import {
  attentionAssets,
  filterAttention,
  summarizeOperations,
  type AttentionFilter,
  type AttentionSeverity,
} from './operations';

interface StatusCard {
  readonly label: string;
  readonly value: string;
  readonly context: string;
  readonly tone: AttentionSeverity | 'good';
  readonly state: string;
}

const timestampFormatter = new Intl.DateTimeFormat('en-US', {
  hour: 'numeric',
  minute: '2-digit',
  month: 'short',
  day: 'numeric',
});

/** Rows shown per watchlist page. Sized to the panel, which sits beside the context aside. */
const ATTENTION_PAGE_SIZE = 8;

/** Administrator landing view: a compact triage surface built from existing API fields. */
@Component({
  selector: 'app-admin-overview',
  imports: [ErrorNotice, Paginator],
  templateUrl: './admin-overview.html',
  styleUrl: './admin-overview.css',
})
export class AdminOverview {
  protected readonly store = inject(AdminStore);
  protected readonly session = inject(SessionStore);
  protected readonly tokens = inject(TokenStore);
  protected readonly experiments = inject(ExperimentStore);

  protected readonly attentionPageSize = ATTENTION_PAGE_SIZE;
  protected readonly summary = computed(() => summarizeOperations(this.store.snapshot()));

  protected readonly severityFilter = signal<AttentionFilter>('');
  protected readonly assetFilter = signal('');
  protected readonly attentionPage = signal(0);

  protected readonly attentionAssets = computed(() => attentionAssets(this.summary().attention));

  protected readonly filteredAttention = computed(() =>
    filterAttention(this.summary().attention, this.severityFilter(), this.assetFilter()),
  );

  protected readonly pagedAttention = computed(() =>
    pageSlice(this.filteredAttention(), this.attentionPage(), ATTENTION_PAGE_SIZE),
  );

  protected readonly expandedAttentionID = signal<string | null>(null);

  protected selectSeverityFilter(event: Event): void {
    this.severityFilter.set((event.target as HTMLSelectElement).value as AttentionFilter);
    this.resetAttentionPaging();
  }

  protected selectAssetFilter(event: Event): void {
    this.assetFilter.set((event.target as HTMLSelectElement).value);
    this.resetAttentionPaging();
  }

  protected toggleAttentionReason(id: string): void {
    this.expandedAttentionID.update((current) => (current === id ? null : id));
  }

  /** A filter change reshuffles the rows, so an open reason row would belong to a row that is
   * no longer on screen — and its `aria-controls` target would vanish with it. */
  private resetAttentionPaging(): void {
    this.attentionPage.set(0);
    this.expandedAttentionID.set(null);
  }

  protected readonly cards = computed<readonly StatusCard[]>(() => {
    const summary = this.summary();
    const queue = this.store.snapshot().queue;
    const onSchedule =
      summary.collections.total - summary.collections.overdue - summary.collections.unscheduled;
    const healthyVaults = summary.vaults.total - summary.vaults.expired - summary.vaults.expiring;
    const queueDepth = queue.pending + queue.processing;
    const failureCount = summary.jobFailures.recent;
    const failureLabel = `${failureCount} ${failureCount === 1 ? 'failure' : 'failures'} in 7 days`;
    const queueTone: StatusCard['tone'] =
      queue.schedulerState === 'stale' ||
      queue.schedulerState === 'unavailable' ||
      summary.jobFailures.critical > 0
        ? 'critical'
        : queue.schedulerState === 'notObserved' || summary.jobFailures.warning > 0
          ? 'warning'
          : queueDepth > 0
            ? 'notice'
            : 'good';

    return [
      {
        label: 'Collections on schedule',
        value: `${onSchedule}/${summary.collections.total}`,
        context:
          summary.collections.overdue > 0
            ? `${summary.collections.overdue} overdue · ${summary.collections.dueSoon} due this week`
            : `${summary.collections.dueSoon} due this week`,
        tone: summary.collections.overdue > 0 ? 'critical' : 'good',
        state: summary.collections.overdue > 0 ? 'Attention' : 'Clear',
      },
      {
        label: 'Collection pipeline',
        value: queue.schedulerState === 'unavailable' ? '—' : String(queueDepth),
        context:
          queue.schedulerState === 'unavailable'
            ? `Queue store unavailable · ${failureLabel}`
            : `${queue.pending} waiting · ${queue.processing} running · ${failureLabel}`,
        tone: queueTone,
        state: this.schedulerStateLabel(queue.schedulerState),
      },
      {
        label: 'Vault credentials healthy',
        value: `${healthyVaults}/${summary.vaults.total}`,
        context: `${summary.vaults.expired} expired · ${summary.vaults.expiring} expire within 30 days`,
        tone:
          summary.vaults.expired > 0
            ? 'critical'
            : summary.vaults.expiring > 0
              ? 'warning'
              : 'good',
        state: summary.vaults.expired > 0 || summary.vaults.expiring > 0 ? 'Attention' : 'Clear',
      },
      {
        label: 'Active service tokens',
        value: String(summary.serviceTokens.active),
        context: `${summary.serviceTokens.expiring} expire within 30 days · ${summary.serviceTokens.revoked} revoked`,
        tone:
          summary.serviceTokens.expired > 0
            ? 'critical'
            : summary.serviceTokens.expiring > 0
              ? 'warning'
              : 'good',
        state:
          summary.serviceTokens.expired > 0 || summary.serviceTokens.expiring > 0
            ? 'Attention'
            : 'Clear',
      },
    ];
  });

  protected readonly loadedAtLabel = computed(() => {
    const loadedAt = this.store.snapshot().loadedAt;
    return loadedAt.getTime() > 0 ? timestampFormatter.format(loadedAt) : '';
  });

  protected readonly schedulerContextLabel = computed(() => {
    const queue = this.store.snapshot().queue;
    if (queue.schedulerState === 'notObserved') {
      return 'Not observed';
    }

    const lastSeen = queue.schedulerLastSeenAt ? Date.parse(queue.schedulerLastSeenAt) : Number.NaN;
    return Number.isFinite(lastSeen)
      ? `${this.schedulerStateLabel(queue.schedulerState)} · ${timestampFormatter.format(lastSeen)}`
      : this.schedulerStateLabel(queue.schedulerState);
  });

  protected severityLabel(severity: AttentionSeverity): string {
    switch (severity) {
      case 'critical':
        return 'Act now';
      case 'warning':
        return 'Upcoming';
      default:
        return 'Review';
    }
  }

  private schedulerStateLabel(state: 'healthy' | 'stale' | 'notObserved' | 'unavailable'): string {
    switch (state) {
      case 'healthy':
        return 'Online';
      case 'stale':
        return 'Stale';
      case 'unavailable':
        return 'Unavailable';
      default:
        return 'Not observed';
    }
  }
}
