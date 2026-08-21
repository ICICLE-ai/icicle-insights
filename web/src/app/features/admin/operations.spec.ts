import { describe, expect, it } from 'vitest';

import type { AdminSnapshot } from './admin-store';
import { summarizeOperations } from './operations';

const NOW = Date.UTC(2026, 7, 20, 12);
const DAY = 24 * 60 * 60 * 1_000;

function at(offsetDays: number): string {
  return new Date(NOW + offsetDays * DAY).toISOString();
}

function snapshot(overrides: Partial<AdminSnapshot> = {}): AdminSnapshot {
  return {
    accounts: [],
    resources: [],
    vaults: [],
    serviceTokens: [],
    admins: [],
    watermarks: [],
    queue: { queue: 'metrics', pending: 0, processing: 0, schedulerState: 'healthy' },
    jobFailures: [],
    loadedAt: new Date(NOW),
    ...overrides,
  };
}

describe('summarizeOperations', () => {
  it('separates overdue, upcoming, and unscheduled collections', () => {
    const result = summarizeOperations(
      snapshot({
        resources: [
          { id: 'late', name: 'Late', nextCollectionAt: at(-2) },
          { id: 'soon', name: 'Soon', nextCollectionAt: at(4) },
          { id: 'later', name: 'Later', nextCollectionAt: at(12) },
          { id: 'unset', name: 'Unset' },
        ],
      }),
      NOW,
    );

    expect(result.collections).toEqual({ total: 4, overdue: 1, dueSoon: 1, unscheduled: 1 });
    expect(result.attention[0]).toMatchObject({ area: 'Collection', asset: 'Late' });
  });

  it('does not treat revoked tokens as active or expiring', () => {
    const result = summarizeOperations(
      snapshot({
        serviceTokens: [
          { id: 'healthy', expiresAt: at(90) },
          { id: 'soon', expiresAt: at(5) },
          { id: 'expired', expiresAt: at(-1) },
          { id: 'revoked', expiresAt: at(5), revokedAt: at(-2) },
        ],
      }),
      NOW,
    );

    expect(result.serviceTokens).toEqual({
      total: 4,
      active: 2,
      revoked: 1,
      expired: 1,
      expiring: 1,
    });
    expect(result.attention.filter((item) => item.area === 'Service token')).toHaveLength(2);
  });

  it('orders expired credentials before upcoming expirations', () => {
    const result = summarizeOperations(
      snapshot({
        vaults: [
          { id: 'upcoming', name: 'Upcoming', expiresAt: at(7) },
          { id: 'expired', name: 'Expired', expiresAt: at(-1) },
        ],
      }),
      NOW,
    );

    expect(result.attention.map((item) => item.asset)).toEqual(['Expired', 'Upcoming']);
    expect(result.attention.map((item) => item.severity)).toEqual(['critical', 'warning']);
  });

  it('surfaces only failures recorded in the last seven days', () => {
    const result = summarizeOperations(
      snapshot({
        jobFailures: [
          {
            id: 'fresh',
            job: 'SyncGitHubRepoStats',
            subject: 'icicle-ai/insights',
            identifier: 'missing_token',
            details: 'Credential missing',
            severity: 'critical',
            failedAt: at(-1),
          },
          {
            id: 'old',
            job: 'SyncGitHubRepoStats',
            subject: 'icicle-ai/old',
            identifier: 'api_request_failed',
            details: 'Transient failure',
            severity: 'warning',
            failedAt: at(-8),
          },
        ],
      }),
      NOW,
    );

    expect(result.jobFailures).toEqual({ recent: 1, critical: 1, warning: 0 });
    expect(result.attention).toHaveLength(1);
    expect(result.attention[0]).toMatchObject({
      area: 'Collection failure',
      asset: 'icicle-ai/insights',
      deadline: '1 day ago',
    });
  });
});
