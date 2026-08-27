import { provideHttpClient } from '@angular/common/http';
import { HttpTestingController, provideHttpClientTesting } from '@angular/common/http/testing';
import { Component, inject, provideZonelessChangeDetection } from '@angular/core';
import { TestBed } from '@angular/core/testing';
import { beforeEach, describe, expect, it } from 'vitest';

import type { Account, Platform, Resource, ResourceLink } from '../../../core/api/models';
import { INSIGHTS_CONFIG, defaultInsightsConfig } from '../../../core/config';
import { DashboardStore } from '../dashboard-store';
import {
  ProvenanceGraph,
  buildProvenanceGraph,
  provenancePlatformColorScale,
} from './provenance-graph';

function makeResource(id: string, name: string, links: readonly ResourceLink[] = []): Resource {
  return { id, name, type: 'dataset', links: [...links] };
}

function platformMap(entries: readonly (readonly [string, Platform])[]): ReadonlyMap<string, Platform> {
  return new Map(entries);
}

describe('buildProvenanceGraph', () => {
  it('turns the CAN Benchmark example into a three-node cluster joined by two edges', () => {
    // The scenario the whole graph exists for: one artifact, imported into Patra, that already
    // exists as a GitHub repository and a Hugging Face dataset. Three `Resource` rows, one thing.
    const datasheet = makeResource('patra-1', 'Continually Adapt or Not (CAN) Benchmark', [
      { id: 'gh-1', name: 'can-benchmark', platform: 'github' },
      { id: 'hf-1', name: 'can_benchmark', platform: 'huggingface' },
    ]);

    const graph = buildProvenanceGraph([datasheet], platformMap([['patra-1', 'patra']]));

    expect(graph.vertices).toHaveLength(3);
    expect(graph.vertices.map((v) => v.id).sort()).toEqual(['gh-1', 'hf-1', 'patra-1']);
    expect(graph.edges).toHaveLength(2);
    expect(graph.edges.every((edge) => edge.source === 'patra-1')).toBe(true);
    expect(graph.edges.map((edge) => edge.target).sort()).toEqual(['gh-1', 'hf-1']);
  });

  it('returns an empty graph for a resource with no links — the state every resource is in today', () => {
    const resource = makeResource('r1', 'lonely-resource', []);

    const graph = buildProvenanceGraph([resource], platformMap([['r1', 'github']]));

    expect(graph.vertices).toHaveLength(0);
    expect(graph.edges).toHaveLength(0);
  });

  it('drops a link with no recorded platform rather than drawing an unidentifiable node', () => {
    const resource = makeResource('r1', 'name', [
      { id: 'x', name: 'x', platform: undefined },
    ]);

    const graph = buildProvenanceGraph([resource], platformMap([['r1', 'github']]));

    expect(graph.vertices).toHaveLength(0);
    expect(graph.edges).toHaveLength(0);
  });

  it('skips a resource whose own platform is not in the lookup, rather than drawing a colourless node', () => {
    const resource = makeResource('r1', 'name', [{ id: 'x', name: 'x', platform: 'github' }]);

    const graph = buildProvenanceGraph([resource], platformMap([]));

    expect(graph.vertices).toHaveLength(0);
    expect(graph.edges).toHaveLength(0);
  });

  it('folds a link recorded from both sides into one edge, not two stacked on each other', () => {
    const alpha = makeResource('a', 'alpha', [{ id: 'b', name: 'beta', platform: 'github' }]);
    const beta = makeResource('b', 'beta', [{ id: 'a', name: 'alpha', platform: 'huggingface' }]);

    const graph = buildProvenanceGraph(
      [alpha, beta],
      platformMap([
        ['a', 'huggingface'],
        ['b', 'github'],
      ]),
    );

    expect(graph.vertices).toHaveLength(2);
    expect(graph.edges).toHaveLength(1);
  });

  it('never draws a self-loop for a link that names its own resource', () => {
    const resource = makeResource('r1', 'name', [{ id: 'r1', name: 'name', platform: 'github' }]);

    const graph = buildProvenanceGraph([resource], platformMap([['r1', 'github']]));

    expect(graph.edges).toHaveLength(0);
  });
});

describe('provenance graph vertex labels', () => {
  it('are exactly two lines: the name, then the platform in parentheses', () => {
    const resource = makeResource('patra-1', 'name', [
      { id: 'hf-1', name: 'MegaDetector', platform: 'huggingface' },
    ]);

    const graph = buildProvenanceGraph([resource], platformMap([['patra-1', 'patra']]));

    const vertex = graph.vertices.find((v) => v.id === 'hf-1');
    expect(vertex?.lines).toEqual(['MegaDetector', '(Hugging Face)']);
  });

  it('spells the second line with each project’s own registry name', () => {
    const resource = makeResource('gh-1', 'insights', [
      { id: 'patra-1', name: 'insights-card', platform: 'patra' },
    ]);

    const graph = buildProvenanceGraph([resource], platformMap([['gh-1', 'github']]));

    const source = graph.vertices.find((v) => v.id === 'gh-1');
    const target = graph.vertices.find((v) => v.id === 'patra-1');
    expect(source?.lines[1]).toBe('(GitHub)');
    expect(target?.lines[1]).toBe('(Patra)');
  });
});

describe('provenancePlatformColorScale', () => {
  const fakePalette = {
    platforms: {
      github: '#111111',
      ghcr: '#222222',
      huggingface: '#333333',
      npm: '#444444',
      pypi: '#555555',
      patra: '#666666',
    } as Record<Platform, string>,
  };

  it('takes every colour from the platform palette rather than a chart-rank slot', () => {
    const resource = makeResource('patra-1', 'name', [
      { id: 'gh-1', name: 'x', platform: 'github' },
      { id: 'hf-1', name: 'y', platform: 'huggingface' },
    ]);
    const graph = buildProvenanceGraph([resource], platformMap([['patra-1', 'patra']]));

    const scale = provenancePlatformColorScale(graph.vertices, fakePalette);

    for (const platform of scale.domain) {
      expect(scale.range[scale.domain.indexOf(platform)]).toBe(fakePalette.platforms[platform]);
    }
  });

  it('gives two different platforms two different colours', () => {
    const resource = makeResource('patra-1', 'name', [
      { id: 'gh-1', name: 'x', platform: 'github' },
      { id: 'hf-1', name: 'y', platform: 'huggingface' },
    ]);
    const graph = buildProvenanceGraph([resource], platformMap([['patra-1', 'patra']]));

    const scale = provenancePlatformColorScale(graph.vertices, fakePalette);

    expect(scale.domain).toEqual(['github', 'huggingface', 'patra']);
    expect(new Set(scale.range).size).toBe(scale.range.length);
  });
});

describe('ProvenanceGraph component', () => {
  async function render(
    resources: readonly Resource[],
    resourcePlatform: ReadonlyMap<string, Platform>,
  ): Promise<HTMLElement> {
    await TestBed.configureTestingModule({
      imports: [ProvenanceGraph],
      providers: [provideZonelessChangeDetection()],
    }).compileComponents();

    const fixture = TestBed.createComponent(ProvenanceGraph);
    fixture.componentRef.setInput('resources', resources);
    fixture.componentRef.setInput('resourcePlatform', resourcePlatform);
    await fixture.whenStable();
    return fixture.nativeElement as HTMLElement;
  }

  it('renders the empty state, not a broken or empty chart, for a resource with no links', async () => {
    const root = await render([makeResource('r1', 'lonely', [])], platformMap([['r1', 'github']]));

    expect(root.querySelector('tanstack-chart')).toBeNull();
    expect(root.querySelector('.ins-provenance-graph__empty')).not.toBeNull();
    expect(root.textContent).toContain('No cross-registry links recorded yet');
  });

  it('renders no empty-state notice once at least one link exists', async () => {
    const resource = makeResource('patra-1', 'name', [
      { id: 'gh-1', name: 'x', platform: 'github' },
    ]);

    const root = await render([resource], platformMap([['patra-1', 'patra']]));

    expect(root.querySelector('.ins-provenance-graph__empty')).toBeNull();
  });
});

/**
 * A test-only stand-in for the `dashboard.html` section that hosts `app-provenance-graph`.
 *
 * Mirrors that section's exact bindings — unscoped `store.catalog().resources`, and
 * `resourceSelect` wired straight to `store.setResourceFilter`, the same call
 * `Dashboard.selectProvenanceResource` makes. Kept intentionally this small (no `AppNav`, no
 * `Router`, no `SessionStore` probe) so the click-through test below stays about this one wiring
 * decision rather than the whole page's unrelated dependency graph.
 */
@Component({
  selector: 'app-provenance-graph-host-fixture',
  imports: [ProvenanceGraph],
  template: `
    <app-provenance-graph
      [resources]="store.catalog().resources"
      [resourcePlatform]="store.catalog().resourcePlatform"
      (resourceSelect)="store.setResourceFilter($event)"
    />
  `,
})
class ProvenanceGraphHostFixture {
  protected readonly store = inject(DashboardStore);
}

/**
 * Regression coverage for a defect code review caught: clicking a provenance node calls
 * `DashboardStore.setResourceFilter`, which narrows `scopedResources()` to that one resource. A
 * `PatraCard`'s `resource_id` is always the Patra-side resource (`PatraCard.swift`), so a link is
 * only ever recorded on *that* resource's own `links` — its GitHub/Hugging Face counterparts
 * never own a card, so their `links` is always `[]`. Feeding the graph `scopedResources()`
 * therefore meant clicking two of every three nodes in a real cluster emptied the graph and
 * showed "No cross-registry links recorded yet" — the same message as the genuinely-empty state.
 *
 * `buildProvenanceGraph`'s own unit tests above never exercised this: they only ever handed it
 * hand-built multi-resource arrays, never the single-resource list the real click handler
 * actually produces via the real store. The two tests below close that gap from different angles:
 * one proves the mechanism through the real `DashboardStore`'s own narrowing, the other drives an
 * actual DOM click through a real Angular template binding and confirms the rendered chart
 * survives it.
 */
describe('provenance graph survives selecting one of its own nodes (regression)', () => {
  let http: HttpTestingController;

  beforeEach(() => {
    TestBed.configureTestingModule({
      imports: [ProvenanceGraphHostFixture],
      providers: [
        provideZonelessChangeDetection(),
        provideHttpClient(),
        provideHttpClientTesting(),
        { provide: INSIGHTS_CONFIG, useValue: defaultInsightsConfig },
      ],
    });
    http = TestBed.inject(HttpTestingController);
  });

  /** `resource()` kicks off from an effect, which does not run in a zoneless test until change
   * detection is pumped — see `dashboard-store.spec.ts`'s identical helper. */
  async function startLoad(): Promise<void> {
    TestBed.tick();
    await Promise.resolve();
  }

  /**
   * Loads a CAN-Benchmark-shaped catalog into a real `DashboardStore`: a Patra datasheet whose
   * own `links` name a GitHub and a Hugging Face counterpart, and those two counterparts with
   * empty `links` of their own — exactly what the real backend returns, per the doc comment
   * above.
   */
  async function loadCanBenchmarkCatalog(): Promise<void> {
    await startLoad();

    const accounts: Account[] = [
      { id: 'acc-gh', name: 'icicle-ai', platform: 'github' },
      { id: 'acc-hf', name: 'icicle-ai', platform: 'huggingface' },
      { id: 'acc-patra', name: 'icicle-ai', platform: 'patra' },
    ];
    const resources: Resource[] = [
      { id: 'gh-1', accountID: 'acc-gh', name: 'can-benchmark', type: 'repository', links: [] },
      { id: 'hf-1', accountID: 'acc-hf', name: 'can_benchmark', type: 'dataset', links: [] },
      {
        id: 'patra-1',
        accountID: 'acc-patra',
        name: 'Continually Adapt or Not (CAN) Benchmark',
        type: 'dataset',
        links: [
          { id: 'gh-1', name: 'can-benchmark', platform: 'github' },
          { id: 'hf-1', name: 'can_benchmark', platform: 'huggingface' },
        ],
      },
    ];

    http.expectOne((r) => r.url.endsWith('/accounts')).flush(accounts);
    http.expectOne((r) => r.url.endsWith('/resources')).flush(resources);
    http.expectOne((r) => r.url.endsWith('/releases')).flush([]);
    for (const call of http.match((r) => r.url.endsWith('/metrics'))) {
      call.flush([]);
    }

    // A macrotask turn, not just microtasks: the resolved `Promise.all` travels through the
    // resource's own internal scheduling before its signals update — same as
    // `dashboard-store.spec.ts`'s failure test.
    await new Promise((resolve) => setTimeout(resolve, 0));
    TestBed.tick();
  }

  it('keeps the whole cluster in the graph’s real input once a click narrows the dashboard’s resource filter', async () => {
    const store = TestBed.inject(DashboardStore);
    await loadCanBenchmarkCatalog();

    expect(store.catalog().resources).toHaveLength(3);

    // The exact call `Dashboard.selectProvenanceResource` makes when a node is clicked — the
    // real scope path a click actually drives, not a hand-rolled re-implementation of
    // `scopedResources`'s own filter.
    store.setResourceFilter('gh-1');

    expect(store.scopedResources()).toHaveLength(1);
    expect(store.scopedResources()[0]?.id).toBe('gh-1');

    // What the graph used to be fed (the bug): only the clicked resource survives scoping, and
    // it owns no `links` of its own, so the graph empties itself even though the cluster is real.
    const scopedGraph = buildProvenanceGraph(
      store.scopedResources(),
      store.catalog().resourcePlatform,
    );
    expect(scopedGraph.vertices).toHaveLength(0);
    expect(scopedGraph.edges).toHaveLength(0);

    // What the graph is fed now (the fix): the unscoped catalog survives the same click intact.
    const catalogGraph = buildProvenanceGraph(
      store.catalog().resources,
      store.catalog().resourcePlatform,
    );
    expect(catalogGraph.vertices).toHaveLength(3);
    expect(catalogGraph.edges).toHaveLength(2);
  });

  it('keeps rendering the chart, not the empty state, after an actual DOM click on a linked node', async () => {
    const fixture = TestBed.createComponent(ProvenanceGraphHostFixture);
    await loadCanBenchmarkCatalog();
    await fixture.whenStable();

    const root = fixture.nativeElement as HTMLElement;
    expect(root.querySelector('.ins-provenance-graph__empty')).toBeNull();
    expect(root.querySelectorAll('tbody tr')).toHaveLength(2);

    // The GitHub counterpart's row link in the paired table — clicking it is the same
    // `resourceSelect` emission a click on its chart node produces (`selectResource` in
    // `ProvenanceGraph`), routed here through the host's real `(resourceSelect)` binding into
    // `store.setResourceFilter`, exactly as `dashboard.html` wires it.
    const links = Array.from(
      root.querySelectorAll<HTMLButtonElement>('.ins-provenance-graph__resource-link'),
    );
    const githubNodeLink = links.find((button) => button.textContent?.includes('can-benchmark'));
    expect(githubNodeLink).toBeDefined();

    githubNodeLink?.click();
    await fixture.whenStable();

    // The click narrowed the dashboard's resource filter to just the GitHub resource — confirms
    // the click actually did what a real one does, not that nothing happened.
    const store = TestBed.inject(DashboardStore);
    expect(store.scopedResources()).toHaveLength(1);
    expect(store.scopedResources()[0]?.id).toBe('gh-1');

    // The regression itself: the graph must still show the whole cluster, not the same "No
    // cross-registry links recorded yet" message the genuinely-empty state shows.
    expect(root.querySelector('.ins-provenance-graph__empty')).toBeNull();
    expect(root.textContent).not.toContain('No cross-registry links recorded yet');
    expect(root.querySelectorAll('tbody tr')).toHaveLength(2);
  });
});
