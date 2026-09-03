import { resolveCollectionOutcome } from './collection-run';

const RESOURCE = 'resource-1';
const DISPATCHED = '2026-08-31T12:00:00.000Z';

function outcome(overrides: Partial<Parameters<typeof resolveCollectionOutcome>[0]> = {}) {
  return resolveCollectionOutcome({
    resourceID: RESOURCE,
    dispatchedAt: DISPATCHED,
    metrics: [],
    failures: [],
    elapsedMs: 0,
    timeoutMs: 60_000,
    ...overrides,
  });
}

function failure(overrides: Record<string, unknown> = {}) {
  return {
    resourceID: RESOURCE,
    job: 'SyncGitHubRepoStats',
    subject: 'icicle-ai/insights',
    identifier: 'api_request_failed',
    details: 'API request failed with status 503',
    severity: 'warning' as const,
    failedAt: '2026-08-31T12:00:30.000Z',
    ...overrides,
  };
}

describe('resolveCollectionOutcome', () => {
  it('waits while nothing has been written yet', () => {
    expect(outcome().state).toBe('running');
  });

  it('reports success once a newer metric exists for the resource', () => {
    const result = outcome({
      metrics: [{ resourceID: RESOURCE, recordedAt: '2026-08-31T12:00:20.000Z' }],
    });
    expect(result.state).toBe('succeeded');
  });

  it('reports failure with the detail an operator has to act on', () => {
    const result = outcome({ failures: [failure()] });
    expect(result.state).toBe('failed');
    expect(result.detail).toBe('API request failed with status 503');
  });

  // A run that wrote metrics and then failed has still failed, and the failure is the actionable
  // half. Reporting success there would send someone away believing a broken collector is fixed.
  it('prefers a failure over a metric written in the same window', () => {
    const result = outcome({
      metrics: [{ resourceID: RESOURCE, recordedAt: '2026-08-31T12:00:20.000Z' }],
      failures: [failure()],
    });
    expect(result.state).toBe('failed');
  });

  it('ignores rows belonging to other resources', () => {
    const result = outcome({
      metrics: [{ resourceID: 'other', recordedAt: '2026-08-31T12:00:20.000Z' }],
      failures: [failure({ resourceID: 'other' })],
    });
    expect(result.state).toBe('running');
  });

  it('ignores rows that predate the dispatch', () => {
    const result = outcome({
      metrics: [{ resourceID: RESOURCE, recordedAt: '2026-08-31T11:00:00.000Z' }],
      failures: [failure({ failedAt: '2026-08-31T11:00:00.000Z' })],
    });
    expect(result.state).toBe('running');
  });

  // The worker stamps these timestamps on its own clock, not the one that stamped the dispatch.
  // Without tolerance, a worker a second behind hides its own result.
  it('accepts a result stamped slightly before the dispatch', () => {
    const result = outcome({
      metrics: [{ resourceID: RESOURCE, recordedAt: '2026-08-31T11:59:58.000Z' }],
    });
    expect(result.state).toBe('succeeded');
  });

  // Two code paths write nothing at all, and a stopped worker looks the same as both. Spinning
  // forever would present a settled question as still open.
  it('gives up honestly once the timeout passes with nothing written', () => {
    const result = outcome({ elapsedMs: 60_000, timeoutMs: 60_000 });
    expect(result.state).toBe('noVerdict');
    expect(result.detail).toContain('queue');
  });

  it('does not guess when the dispatch timestamp is unreadable', () => {
    expect(outcome({ dispatchedAt: 'not a date' }).state).toBe('noVerdict');
  });
});
