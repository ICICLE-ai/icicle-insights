import type { JobFailureInsight, Metric } from '../../../core/api/models';

/**
 * What a manually triggered collection has done so far.
 *
 * `noVerdict` is a real outcome, not a fallback for laziness. Two paths write nothing at all: a
 * resource deleted between dispatch and dequeue is skipped deliberately, and persisting a failure
 * row is best-effort so the worker is never stranded by it. A stopped worker looks identical to
 * both. Reporting "no verdict" is the only honest thing to show; a spinner that never resolves
 * pretends the question is still open when nothing is coming.
 */
export type CollectionRunState = 'running' | 'succeeded' | 'failed' | 'noVerdict';

export interface CollectionRunOutcome {
  readonly state: CollectionRunState;
  /** Ready to show as-is. Says what was observed, never that this dispatch caused it. */
  readonly detail: string;
}

/**
 * Clock skew allowance between the API that stamped the dispatch and the worker that stamps the
 * result.
 *
 * Both `Metric.recordedAt` and `JobFailure.failedAt` are set in Swift by the worker process, not by
 * PostgreSQL, so they come off a different machine's clock than `dispatchedAt`. A worker running a
 * second or two behind would make a genuinely new row look older than the dispatch and the run
 * would report `noVerdict` while sitting on its own answer. Erring wide costs only the chance of
 * attributing a result that landed just before the click.
 */
const CLOCK_SKEW_TOLERANCE_MS = 5_000;

/**
 * Decides what to report for a run, from rows the dashboard already fetches.
 *
 * Correlates on resource plus recency alone, which is all that is available: nothing ties a metric
 * or a failure back to the dispatch that produced it. A scheduled sweep landing in the same window
 * is therefore indistinguishable, and that is likeliest in exactly the case being debugged, since a
 * credential failure re-books its resource an hour out. Hence `detail` reports the observation and
 * never the causation.
 *
 * Failure wins a tie. A run that wrote metrics and then failed has still failed, and the failure is
 * the part worth surfacing.
 */
export function resolveCollectionOutcome(params: {
  readonly resourceID: string;
  readonly dispatchedAt: string;
  readonly metrics: readonly Metric[];
  readonly failures: readonly JobFailureInsight[];
  readonly elapsedMs: number;
  readonly timeoutMs: number;
}): CollectionRunOutcome {
  const { resourceID, dispatchedAt, metrics, failures, elapsedMs, timeoutMs } = params;
  const since = Date.parse(dispatchedAt) - CLOCK_SKEW_TOLERANCE_MS;

  if (!Number.isFinite(since)) {
    return { state: 'noVerdict', detail: 'The dispatch timestamp could not be read.' };
  }

  const failure = failures.find(
    (item) => item.resourceID === resourceID && isAfter(item.failedAt, since),
  );
  if (failure) {
    return { state: 'failed', detail: failure.details };
  }

  const metric = metrics.find(
    (item) => item.resourceID === resourceID && isAfter(item.recordedAt, since),
  );
  if (metric) {
    return {
      state: 'succeeded',
      detail: `Metrics recorded at ${new Date(Date.parse(metric.recordedAt ?? '')).toLocaleTimeString()}.`,
    };
  }

  if (elapsedMs >= timeoutMs) {
    return {
      state: 'noVerdict',
      detail:
        'No result appeared. The job may still be queued behind others, or no worker is draining the queue — check queue depth on the operations console.',
    };
  }

  return { state: 'running', detail: 'Waiting for the worker to report.' };
}

function isAfter(timestamp: string | undefined, since: number): boolean {
  if (!timestamp) {
    return false;
  }
  const parsed = Date.parse(timestamp);
  return Number.isFinite(parsed) && parsed >= since;
}
