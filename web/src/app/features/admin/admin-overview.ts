import { Component, computed, inject } from '@angular/core';

import { SessionStore } from '../../core/auth/session-store';
import { TokenStore } from '../../core/auth/token-store';
import { ExperimentStore } from '../../core/layout/experiment-store';
import { ErrorNotice } from '../../shared/ui/error-notice';
import { AdminStore } from './admin-store';
import { summarizeOperations, type AttentionSeverity } from './operations';

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

/** Administrator landing view: a compact triage surface built from existing API fields. */
@Component({
  selector: 'app-admin-overview',
  imports: [ErrorNotice],
  templateUrl: './admin-overview.html',
  styleUrl: './admin-overview.css',
})
export class AdminOverview {
  protected readonly store = inject(AdminStore);
  protected readonly session = inject(SessionStore);
  protected readonly tokens = inject(TokenStore);
  protected readonly experiments = inject(ExperimentStore);

  protected readonly summary = computed(() => summarizeOperations(this.store.snapshot()));
  protected readonly topAttention = computed(() => this.summary().attention.slice(0, 7));
  protected readonly hiddenAttentionCount = computed(() =>
    Math.max(0, this.summary().attention.length - this.topAttention().length),
  );

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
