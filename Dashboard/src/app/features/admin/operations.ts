import type { JobFailureInsight, Resource, ServiceToken, Vault } from '../../core/api/models';
import type { AdminSnapshot } from './admin-store';

export type AttentionSeverity = 'critical' | 'warning' | 'notice';

export interface AttentionItem {
  readonly id: string;
  readonly severity: AttentionSeverity;
  readonly area: 'Collection' | 'Collection failure' | 'Vault' | 'Service token';
  readonly asset: string;
  readonly deadline: string;
  readonly dueAt: number;
  /** Why this item needs attention now, in enough detail to act without opening the record. */
  readonly reason: string;
}

export interface OperationalSummary {
  readonly collections: {
    readonly total: number;
    readonly overdue: number;
    readonly dueSoon: number;
    readonly unscheduled: number;
  };
  readonly vaults: {
    readonly total: number;
    readonly expired: number;
    readonly expiring: number;
  };
  readonly serviceTokens: {
    readonly total: number;
    readonly active: number;
    readonly revoked: number;
    readonly expired: number;
    readonly expiring: number;
  };
  readonly admins: {
    readonly total: number;
    readonly roots: number;
  };
  readonly jobFailures: {
    readonly recent: number;
    readonly critical: number;
    readonly warning: number;
  };
  readonly attention: readonly AttentionItem[];
}

const DAY = 24 * 60 * 60 * 1_000;
const COLLECTION_RUNWAY = 7 * DAY;
const CREDENTIAL_RUNWAY = 30 * DAY;
const RECENT_FAILURE_WINDOW = 7 * DAY;

/** Pure operational reduction so the status math can be tested independently of Angular. */
export function summarizeOperations(snapshot: AdminSnapshot, now = Date.now()): OperationalSummary {
  const collectionDates = snapshot.resources.map((item) => dateValue(item.nextCollectionAt));
  const overdueResources = snapshot.resources.filter((item) => isPast(item.nextCollectionAt, now));
  const dueSoonResources = snapshot.resources.filter((item) =>
    isWithinRunway(item.nextCollectionAt, now, COLLECTION_RUNWAY),
  );
  const expiredVaults = snapshot.vaults.filter((item) => isPast(item.expiresAt, now));
  const expiringVaults = snapshot.vaults.filter((item) =>
    isWithinRunway(item.expiresAt, now, CREDENTIAL_RUNWAY),
  );
  const revokedTokens = snapshot.serviceTokens.filter((item) => Boolean(item.revokedAt));
  const liveTokens = snapshot.serviceTokens.filter((item) => !item.revokedAt);
  const expiredTokens = liveTokens.filter((item) => isPast(item.expiresAt, now));
  const expiringTokens = liveTokens.filter((item) =>
    isWithinRunway(item.expiresAt, now, CREDENTIAL_RUNWAY),
  );
  const recentFailures = snapshot.jobFailures.filter((item) =>
    isRecent(item.failedAt, now, RECENT_FAILURE_WINDOW),
  );

  const attention = [
    ...overdueResources.map((item) => resourceAttention(item, now)),
    ...expiredVaults.map((item) => vaultAttention(item, now, 'critical')),
    ...expiringVaults.map((item) => vaultAttention(item, now, 'warning')),
    ...expiredTokens.map((item) => tokenAttention(item, now, 'critical')),
    ...expiringTokens.map((item) => tokenAttention(item, now, 'warning')),
    ...recentFailures.map((item) => failureAttention(item, now)),
  ].sort((a, b) => severityRank(a.severity) - severityRank(b.severity) || a.dueAt - b.dueAt);

  return {
    collections: {
      total: snapshot.resources.length,
      overdue: overdueResources.length,
      dueSoon: dueSoonResources.length,
      unscheduled: collectionDates.filter((value) => value === null).length,
    },
    vaults: {
      total: snapshot.vaults.length,
      expired: expiredVaults.length,
      expiring: expiringVaults.length,
    },
    serviceTokens: {
      total: snapshot.serviceTokens.length,
      active: liveTokens.length - expiredTokens.length,
      revoked: revokedTokens.length,
      expired: expiredTokens.length,
      expiring: expiringTokens.length,
    },
    admins: {
      total: snapshot.admins.length,
      roots: snapshot.admins.filter((admin) => admin.isRoot).length,
    },
    jobFailures: {
      recent: recentFailures.length,
      critical: recentFailures.filter((failure) => failure.severity === 'critical').length,
      warning: recentFailures.filter((failure) => failure.severity === 'warning').length,
    },
    attention,
  };
}

function failureAttention(failure: JobFailureInsight, now: number): AttentionItem {
  const failedAt = dateValue(failure.failedAt) ?? now;
  return {
    id: `failure-${failure.id ?? `${failure.identifier}-${failedAt}`}`,
    severity: failure.severity,
    area: 'Collection failure',
    asset: failure.subject,
    deadline: relativeOccurrence(failedAt, now),
    // Newer failures should lead within the same severity, hence the inverted sort key.
    dueAt: -failedAt,
    reason: `${failure.job} failed ${relativeOccurrence(failedAt, now)}: ${failure.details}`,
  };
}

function resourceAttention(resource: Resource, now: number): AttentionItem {
  const dueAt = dateValue(resource.nextCollectionAt) ?? now;
  const cadence = resource.collectionIntervalDays;
  const name = resource.name ?? 'This resource';
  return {
    id: `collection-${resource.id ?? resource.name ?? dueAt}`,
    severity: 'critical',
    area: 'Collection',
    asset: resource.name ?? 'Unnamed resource',
    deadline: relativeDeadline(dueAt, now),
    dueAt,
    reason: cadence
      ? `${name} was due to sync ${relativeDeadline(dueAt, now)} on its ${cadence}-day cadence, but no sweep has picked it up. Every day past due is a gap in its metric history.`
      : `${name} was due to sync ${relativeDeadline(dueAt, now)}, but no sweep has picked it up. Every day past due is a gap in its metric history.`,
  };
}

function vaultAttention(vault: Vault, now: number, severity: AttentionSeverity): AttentionItem {
  const dueAt = dateValue(vault.expiresAt) ?? now;
  const name = vault.name ?? 'This vault credential';
  return {
    id: `vault-${vault.id ?? vault.name ?? dueAt}`,
    severity,
    area: 'Vault',
    asset: vault.name ?? 'Unnamed vault credential',
    deadline: relativeDeadline(dueAt, now),
    dueAt,
    reason:
      severity === 'critical'
        ? `${name} expired ${relativeDeadline(dueAt, now)}. Collection for its account is failing authentication right now — rotate it to restore syncing.`
        : `${name} expires ${relativeDeadline(dueAt, now)}. Rotate it before then, or collection for its account will start failing authentication.`,
  };
}

function tokenAttention(
  token: ServiceToken,
  now: number,
  severity: AttentionSeverity,
): AttentionItem {
  const dueAt = dateValue(token.expiresAt) ?? now;
  const name = token.label ?? 'This service token';
  return {
    id: `token-${token.id ?? token.jti ?? dueAt}`,
    severity,
    area: 'Service token',
    asset: token.label ?? 'Unlabelled service token',
    deadline: relativeDeadline(dueAt, now),
    dueAt,
    reason:
      severity === 'critical'
        ? `${name} expired ${relativeDeadline(dueAt, now)}. The service holding it can no longer authenticate its webhook calls — reissue a replacement.`
        : `${name} expires ${relativeDeadline(dueAt, now)}. Reissue it before then so the service it authenticates does not lose access.`,
  };
}

function isPast(value: string | undefined, now: number): boolean {
  const time = dateValue(value);
  return time !== null && time <= now;
}

function isWithinRunway(value: string | undefined, now: number, runway: number): boolean {
  const time = dateValue(value);
  return time !== null && time > now && time <= now + runway;
}

function isRecent(value: string | undefined, now: number, window: number): boolean {
  const time = dateValue(value);
  return time !== null && time <= now && time >= now - window;
}

function dateValue(value: string | undefined): number | null {
  if (!value) {
    return null;
  }

  const time = Date.parse(value);
  return Number.isFinite(time) ? time : null;
}

function relativeDeadline(time: number, now: number): string {
  const days = Math.ceil(Math.abs(time - now) / DAY);
  if (time <= now) {
    return days <= 1 ? 'due now' : `${days} days overdue`;
  }
  return days <= 1 ? 'within 1 day' : `in ${days} days`;
}

function relativeOccurrence(time: number, now: number): string {
  const elapsed = Math.max(0, now - time);
  const minutes = Math.max(1, Math.round(elapsed / 60_000));
  if (minutes < 60) {
    return `${minutes} min ago`;
  }

  const hours = Math.round(elapsed / (60 * 60 * 1_000));
  if (hours < 24) {
    return `${hours} hr ago`;
  }

  const days = Math.round(elapsed / DAY);
  return `${days} ${days === 1 ? 'day' : 'days'} ago`;
}

function severityRank(severity: AttentionSeverity): number {
  switch (severity) {
    case 'critical':
      return 0;
    case 'warning':
      return 1;
    default:
      return 2;
  }
}

/** Empty string means "no filter" for either watchlist dimension. */
export type AttentionFilter = AttentionSeverity | '';

/**
 * Narrows the watchlist by severity and asset together.
 *
 * Preserves order rather than re-sorting: `summarizeOperations` already ranked by severity and
 * then deadline, and that ordering is what makes the first page the one worth reading.
 */
export function filterAttention(
  items: readonly AttentionItem[],
  severity: AttentionFilter,
  asset: string,
): readonly AttentionItem[] {
  if (severity === '' && asset === '') {
    return items;
  }
  return items.filter(
    (item) =>
      (severity === '' || item.severity === severity) && (asset === '' || item.asset === asset),
  );
}

/**
 * Distinct assets on the watchlist, for the filter's option list.
 *
 * Callers pass the *unfiltered* items. Deriving options from the filtered set would delete every
 * option but the selected one as soon as a filter applied, leaving no way back to a wider view.
 */
export function attentionAssets(items: readonly AttentionItem[]): readonly string[] {
  return [...new Set(items.map((item) => item.asset))].sort((a, b) => a.localeCompare(b));
}
