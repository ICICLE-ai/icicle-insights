import { provideHttpClient } from '@angular/common/http';
import { HttpTestingController, provideHttpClientTesting } from '@angular/common/http/testing';
import { provideZonelessChangeDetection } from '@angular/core';
import { TestBed } from '@angular/core/testing';
import { beforeEach, describe, expect, it } from 'vitest';

import { ALL_METRIC_TYPES } from '../../core/api/insights-api';
import { INSIGHTS_CONFIG, defaultInsightsConfig } from '../../core/config';
import { DashboardStore } from './dashboard-store';

describe('DashboardStore', () => {
  let http: HttpTestingController;

  beforeEach(() => {
    TestBed.configureTestingModule({
      providers: [
        provideZonelessChangeDetection(),
        provideHttpClient(),
        provideHttpClientTesting(),
        { provide: INSIGHTS_CONFIG, useValue: defaultInsightsConfig },
      ],
    });
    http = TestBed.inject(HttpTestingController);
  });

  /**
   * Starts the resource's loader.
   *
   * `resource()` kicks off from an effect, and effects do not run in a zoneless test until
   * change detection is pumped — so reading the signal is not enough. Without the tick no
   * request is ever issued, and every assertion afterwards measures an idle store rather than
   * the behaviour under test.
   */
  async function startLoad() {
    TestBed.tick();
    await Promise.resolve();
  }

  it('asks for every metric type separately rather than one unscoped page', async () => {
    const store = TestBed.inject(DashboardStore);
    void store;
    await startLoad();

    const metricCalls = http.match((r) => r.url.endsWith('/metrics'));

    // One request per member of the closed MetricType enum. Fetching unscoped instead would cap
    // at 1000 rows across all types and silently truncate the rarer ones out of existence.
    //
    // Measured against `ALL_METRIC_TYPES.length` rather than a hardcoded count: a literal here
    // is exactly the kind of number that drifted silently when `deployments` was added to the
    // Swift `MetricType` enum but not to this array (see `metric-types.spec.ts`), and this test
    // would have kept passing throughout since it never touches the array itself.
    expect(metricCalls).toHaveLength(ALL_METRIC_TYPES.length);
    expect(metricCalls.every((call) => call.request.params.has('type'))).toBe(true);
    expect(new Set(metricCalls.map((call) => call.request.params.get('type'))).size).toBe(
      ALL_METRIC_TYPES.length,
    );
  });

  it('reports a failed load as an error instead of loading forever', async () => {
    const store = TestBed.inject(DashboardStore);
    await startLoad();

    // A plain server failure. Note what this deliberately does *not* simulate: the fallback
    // case of a 200 carrying an HTML body. `HttpTestingController` delivers a flushed body
    // without running the JSON parser, so that response arrives looking like valid data and the
    // load succeeds — the failure only exists in a real transport. Its mapping is covered
    // directly in `api-error.spec.ts` instead; what matters here is that *any* rejected load
    // ends in an error state rather than perpetual skeletons.
    for (const call of http.match(() => true)) {
      call.flush(null, { status: 500, statusText: 'Internal Server Error' });
    }

    // Let the rejected loader settle and the resource commit its error state. A macrotask turn,
    // not just microtasks: the rejection travels through Promise.all and the resource's own
    // internal scheduling before the signals update.
    await new Promise((resolve) => setTimeout(resolve, 0));
    TestBed.tick();

    expect(store.isLoading()).toBe(false);
    expect(store.error()).toBeTruthy();
  });
});
