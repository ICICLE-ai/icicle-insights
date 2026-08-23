import { describe, expect, it } from 'vitest';

import type { AdminSnapshot } from './admin-store';
import {
  attentionAssets,
  filterAttention,
  summarizeOperations,
  type AttentionItem,
} from './operations';

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

/** A watchlist row with only the fields the filters read. */
function attention(id: string, severity: AttentionItem['severity'], asset: string): AttentionItem {
  return { id, severity, area: 'Collection', asset, deadline: 'now', dueAt: 0, reason: '' };
}

const WATCHLIST: readonly AttentionItem[] = [
  attention('a', 'critical', 'icicle-ai/insights'),
  attention('b', 'critical', 'icicle-ai/tapis'),
  attention('c', 'warning', 'icicle-ai/insights'),
  attention('d', 'notice', 'icicle-ai/ci'),
];

describe('filterAttention', () => {
  it('returns everything when neither filter is set', () => {
    expect(filterAttention(WATCHLIST, '', '')).toStrictEqual(WATCHLIST);
  });

  it('narrows by severity alone', () => {
    expect(filterAttention(WATCHLIST, 'critical', '').map((item) => item.id)).toStrictEqual([
      'a',
      'b',
    ]);
  });

  it('narrows by asset alone', () => {
    expect(
      filterAttention(WATCHLIST, '', 'icicle-ai/insights').map((item) => item.id),
    ).toStrictEqual(['a', 'c']);
  });

  it('combines the two filters with AND, not OR', () => {
    expect(
      filterAttention(WATCHLIST, 'critical', 'icicle-ai/insights').map((item) => item.id),
    ).toStrictEqual(['a']);
  });

  it('returns nothing for a combination no row satisfies', () => {
    expect(filterAttention(WATCHLIST, 'notice', 'icicle-ai/tapis')).toStrictEqual([]);
  });

  it('preserves the incoming severity-then-deadline order', () => {
    // The panel shows the first page only, so reordering here would bury the urgent rows.
    const filtered = filterAttention(WATCHLIST, '', 'icicle-ai/insights');
    expect(filtered.map((item) => item.severity)).toStrictEqual(['critical', 'warning']);
  });
});

describe('attentionAssets', () => {
  it('lists each asset once, alphabetically', () => {
    expect(attentionAssets(WATCHLIST)).toStrictEqual([
      'icicle-ai/ci',
      'icicle-ai/insights',
      'icicle-ai/tapis',
    ]);
  });

  it('keeps every option available once a filter has narrowed the rows', () => {
    // Options come from the unfiltered list precisely so a chosen filter cannot strand the user
    // with no way back to a wider view.
    const narrowed = filterAttention(WATCHLIST, 'notice', '');
    expect(attentionAssets(WATCHLIST)).toHaveLength(3);
    expect(narrowed).toHaveLength(1);
  });

  it('is empty for an empty watchlist', () => {
    expect(attentionAssets([])).toStrictEqual([]);
  });
});
