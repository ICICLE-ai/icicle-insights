import { Component, computed, inject, input, output } from '@angular/core';

import type { Platform, Resource } from '../../../core/api/models';
import { ChartFigure } from '../../../shared/charts/chart-figure';
import { ChartPaletteService, type ChartPalette } from '../../../shared/charts/chart-palette';
import { pluralize } from '../../../shared/format/formatters';
import { PLATFORM_ORDER, platformLabel } from '../../../shared/format/labels';

/**
 * One vertex in the provenance graph: a single `Resource` row, joined to every other row Patra
 * recorded as the same real artifact.
 */
export interface ProvenanceGraphVertex {
  readonly id: string;
  readonly resourceID: string;
  readonly label: string;
  readonly platform: Platform;
  /** Exactly two lines: the resource name, then its platform in parentheses on its own line.
   * Kept as two separate strings — rather than one that happens to contain a line break — so a
   * name long enough to wrap onto a second line of its own can never be confused with this. */
  readonly lines: readonly [string, string];
}

/** One provenance link: two `Resource` rows a Patra card recorded as the same artifact. */
export interface ProvenanceGraphEdge {
  readonly source: string;
  readonly target: string;
}

/**
 * One drawn cluster: one hub resource plus up to `MAX_VISIBLE_SPOKES` of the other registries it
 * was also recorded under. A cluster is a connected component of the graph — see
 * `buildProvenanceClusters` for how the hub is chosen and what happens past the visible cap.
 */
export interface ProvenanceCluster {
  readonly id: string;
  readonly hub: ProvenanceGraphVertex;
  readonly spokes: readonly ProvenanceGraphVertex[];
  /** Members of this cluster beyond `spokes.length` that the card does not draw. Always zero
   * against every cluster in the catalog today; the accessible table lists every one of them
   * regardless, so nothing is actually lost when this is positive — only the card preview caps. */
  readonly overflowCount: number;
}

/** One row of the paired accessible table: one recorded link, both of its endpoints. */
interface ProvenanceTableRow {
  readonly id: string;
  readonly sourceResourceID: string;
  readonly sourceName: string;
  readonly sourcePlatform: Platform;
  readonly targetResourceID: string;
  readonly targetName: string;
  readonly targetPlatform: Platform;
}

/** Card previews stop here and fold the rest into "+N more"; the table below is unaffected and
 * always lists every member. Three spokes plus the hub is four nodes per card, matching the
 * largest cluster the catalog has produced so far — see the class doc comment for why this chart
 * no longer tries to fit an unbounded cluster onto one canvas at all. */
const MAX_VISIBLE_SPOKES = 3;

/**
 * Same artifact, several registries: Patra imports models and datasets that already exist
 * elsewhere, so one real artifact often shows up as several `Resource` rows — the CAN Benchmark
 * is a GitHub repository, a Hugging Face dataset, and a Patra datasheet, three rows for one
 * thing. This graph is what shows a reader that those rows are the same thing.
 *
 * Layout is a deterministic grid of small, self-contained cards, one per artifact — not a d3
 * force simulation. `forceLayout` (still used by `release-graph.ts`) is the right tool when a
 * chart renders exactly one connected cluster at a time, because a period selector guarantees
 * that. This graph has no selector: every artifact Patra has ever cross-linked renders at once,
 * and those artifacts are disjoint components with no edges between them. A single simulation
 * over several disjoint components has nothing pulling the components apart from each other —
 * `manyBody` repels every node from every other node in the whole graph, not just the ones it
 * shares an edge with, so five small unconnected clusters settle into one overlapping blob
 * instead of five legible ones, and their labels truncate fighting for space inside a circle
 * sized for physics rather than text. None of that was a bug in the simulation; it was the
 * simulation solving a problem this chart does not have. The data is small, disjoint groups of
 * two to four nodes each — essentially one Patra resource pointing at one or two external ones —
 * which a CSS grid of cards expresses directly, with no physics and no randomness, so the same
 * catalog always renders in exactly the same place.
 */
@Component({
  selector: 'app-provenance-graph',
  imports: [ChartFigure],
  template: `
    <app-chart-figure heading="Provenance graph" [subtitle]="subtitle()">
      @if (hasLinks()) {
        <div chart class="ins-provenance-graph">
          <div class="ins-provenance-graph__legend" role="list" aria-label="Registry colours used below">
            @for (platform of legendPlatforms(); track platform) {
              <span class="ins-provenance-graph__legend-item" role="listitem">
                <span
                  class="ins-provenance-graph__legend-swatch"
                  [style.--ins-provenance-accent]="colorFor(platform)"
                  aria-hidden="true"
                ></span>
                {{ registryLabel(platform) }}
              </span>
            }
          </div>

          <div class="ins-provenance-graph__grid">
            @for (cluster of clusters(); track cluster.id) {
              <div class="ins-provenance-cluster" role="group" [attr.aria-label]="clusterLabel(cluster)">
                <button
                  type="button"
                  class="ins-provenance-node ins-provenance-node--hub"
                  [style.--ins-provenance-accent]="colorFor(cluster.hub.platform)"
                  (click)="selectResource(cluster.hub.resourceID)"
                >
                  <span class="ins-provenance-node__name">{{ cluster.hub.lines[0] }}</span>
                  <span class="ins-provenance-node__platform">{{ cluster.hub.lines[1] }}</span>
                </button>

                <div class="ins-provenance-cluster__connector" aria-hidden="true"></div>
                <p class="ins-provenance-cluster__caption ins-eyebrow">Also registered as</p>

                <div class="ins-provenance-cluster__spokes">
                  @for (spoke of cluster.spokes; track spoke.id) {
                    <button
                      type="button"
                      class="ins-provenance-node"
                      [style.--ins-provenance-accent]="colorFor(spoke.platform)"
                      (click)="selectResource(spoke.resourceID)"
                    >
                      <span class="ins-provenance-node__name">{{ spoke.lines[0] }}</span>
                      <span class="ins-provenance-node__platform">{{ spoke.lines[1] }}</span>
                    </button>
                  }
                  @if (cluster.overflowCount > 0) {
                    <span class="ins-provenance-cluster__overflow">
                      +{{ cluster.overflowCount }} more in the table below
                    </span>
                  }
                </div>
              </div>
            }
          </div>
        </div>
      } @else {
        <!-- The collector that populates links runs in a later task, so this is the ordinary
             state today — not a bug. An empty SVG with no explanation would read as one. -->
        <div chart class="ins-provenance-graph__empty">
          <p class="ins-provenance-graph__empty-title">No cross-registry links recorded yet</p>
          <p class="ins-provenance-graph__empty-hint">
            Patra's catalog sync records when an imported artifact also exists in another
            registry. This graph fills in once that sync has run.
          </p>
        </div>
      }

      <table table class="ins-chart-table">
        <caption class="ins-visually-hidden">
          Every resource joined to the other registries recorded for the same artifact.
        </caption>
        <thead>
          <tr>
            <th scope="col">Resource</th>
            <th scope="col">Registry</th>
            <th scope="col">Also registered as</th>
            <th scope="col">Registry</th>
          </tr>
        </thead>
        <tbody>
          @for (row of tableRows(); track row.id) {
            <tr>
              <th scope="row">
                <button
                  type="button"
                  class="ins-provenance-graph__resource-link"
                  (click)="selectResource(row.sourceResourceID)"
                >
                  {{ row.sourceName }}
                </button>
              </th>
              <td>{{ registryLabel(row.sourcePlatform) }}</td>
              <td>
                <button
                  type="button"
                  class="ins-provenance-graph__resource-link"
                  (click)="selectResource(row.targetResourceID)"
                >
                  {{ row.targetName }}
                </button>
              </td>
              <td>{{ registryLabel(row.targetPlatform) }}</td>
            </tr>
          }
        </tbody>
      </table>
    </app-chart-figure>
  `,
  styles: `
    :host {
      display: flex;
      min-height: 0;
    }

    app-chart-figure {
      flex: 1 1 auto;
      min-height: 0;
    }

    .ins-provenance-graph {
      display: flex;
      flex-direction: column;
      gap: 0.75rem;
      min-width: 0;
    }

    .ins-provenance-graph__legend {
      display: flex;
      flex-wrap: wrap;
      gap: 0.375rem 0.875rem;
    }

    .ins-provenance-graph__legend-item {
      display: inline-flex;
      align-items: center;
      gap: 0.375rem;
      font-size: var(--ins-text-micro);
      color: var(--ins-ink-muted);
    }

    .ins-provenance-graph__legend-swatch {
      width: 0.5625rem;
      height: 0.5625rem;
      background: var(--ins-provenance-accent);
      border-radius: 50%;
    }

    /* One grid cell per artifact. Cells cannot overlap by construction — this is what replaces
       the collision force — and the auto-fill column count reflows with the viewport instead
       of a media-query breakpoint. */
    .ins-provenance-graph__grid {
      display: grid;
      grid-template-columns: repeat(auto-fill, minmax(15rem, 1fr));
      align-items: start;
      gap: 0.875rem;
    }

    .ins-provenance-cluster {
      display: flex;
      flex-direction: column;
      align-items: center;
      gap: 0.375rem;
      padding: 0.875rem;
      background: var(--ins-surface);
      border: 1px solid var(--ins-border);
      border-radius: var(--ins-radius);
    }

    .ins-provenance-cluster__connector {
      width: 1px;
      height: 0.625rem;
      background: var(--ins-border-strong);
    }

    .ins-provenance-cluster__caption {
      margin: 0;
    }

    .ins-provenance-cluster__spokes {
      display: flex;
      flex-wrap: wrap;
      align-items: flex-start;
      justify-content: center;
      gap: 0.5rem;
    }

    .ins-provenance-cluster__overflow {
      display: flex;
      align-items: center;
      padding: 0.375rem 0.625rem;
      font-size: var(--ins-text-micro);
      color: var(--ins-ink-muted);
      text-align: center;
    }

    .ins-provenance-node {
      display: flex;
      flex-direction: column;
      align-items: center;
      gap: 0.125rem;
      min-width: 7.5rem;
      max-width: 15rem;
      padding: 0.5rem 0.75rem;
      color: var(--ins-ink);
      text-align: center;
      background: var(--ins-raised);
      border: 1.5px solid
        color-mix(in srgb, var(--ins-provenance-accent) 55%, var(--ins-border-strong));
      border-radius: var(--ins-radius-sm);
      font: inherit;
      cursor: pointer;
      /* Wrap rather than clip. A fixed-width circle is exactly what made the previous layout
         truncate long names — a rectangle that wraps text never has to. */
      overflow-wrap: break-word;
    }

    .ins-provenance-node--hub {
      width: 100%;
      max-width: 100%;
      border-width: 2px;
      background: color-mix(in srgb, var(--ins-provenance-accent) 12%, var(--ins-surface));
    }

    .ins-provenance-node__name {
      font-weight: 650;
      font-size: var(--ins-text-small);
      overflow-wrap: break-word;
    }

    .ins-provenance-node__platform {
      font-size: var(--ins-text-micro);
      color: var(--ins-ink-muted);
    }

    .ins-provenance-node:hover {
      background: color-mix(in srgb, var(--ins-provenance-accent) 18%, var(--ins-surface));
    }

    .ins-provenance-node:focus-visible {
      outline: 3px solid color-mix(in srgb, var(--ins-provenance-accent) 55%, transparent);
      outline-offset: 1px;
    }

    .ins-provenance-graph__empty {
      display: flex;
      flex: 1 1 auto;
      flex-direction: column;
      align-items: center;
      justify-content: center;
      min-height: 12rem;
      padding: 3rem 1.5rem;
      text-align: center;
      background: var(--ins-surface);
      border: 1px dashed var(--ins-border-strong);
      border-radius: var(--ins-radius);
    }

    .ins-provenance-graph__empty-title {
      margin: 0;
      font-weight: 600;
      color: var(--ins-ink);
    }

    .ins-provenance-graph__empty-hint {
      max-width: 32rem;
      margin: 0.375rem 0 0;
      font-size: var(--ins-text-small);
      color: var(--ins-ink-muted);
    }

    .ins-provenance-graph__resource-link {
      padding: 0;
      color: var(--ins-series-1);
      background: transparent;
      border: 0;
      font: inherit;
      text-decoration: underline;
      text-underline-offset: 0.15em;
      cursor: pointer;
    }
  `,
})
export class ProvenanceGraph {
  /**
   * The full catalog, deliberately unscoped by the dashboard's current filter selection.
   *
   * A link is only ever recorded on the Patra-side `Resource` — its GitHub/Hugging Face
   * counterparts never own a `PatraCard`, so their own `links` is always empty (see
   * `buildProvenanceGraph`). Pass `DashboardStore.scopedResources()` here instead and the graph
   * empties itself the moment someone clicks one of those counterpart nodes: selecting a node
   * narrows the dashboard's resource filter to just that one resource, which is exactly the input
   * this component needs to stay whole. Always wire this to `store.catalog().resources`.
   */
  readonly resources = input.required<readonly Resource[]>();
  /** Resource id → the platform of the account that owns it, from `DashboardStore.catalog()`.
   * Needed because a resource's own platform is not carried on `Resource` itself — only a
   * *link's* platform is, since that comes straight off the DTO. */
  readonly resourcePlatform = input.required<ReadonlyMap<string, Platform>>();
  readonly resourceSelect = output<string>();

  private readonly paletteService = inject(ChartPaletteService);

  protected readonly registryLabel = platformLabel;

  private readonly graph = computed(() =>
    buildProvenanceGraph(this.resources(), this.resourcePlatform()),
  );

  protected readonly hasLinks = computed(() => this.graph().edges.length > 0);

  protected readonly subtitle = computed(() => {
    const { vertices, edges } = this.graph();
    if (edges.length === 0) {
      return 'No provenance links recorded yet.';
    }
    return `${pluralize(vertices.length, 'resource')} · ${pluralize(edges.length, 'link')}`;
  });

  /** One row per edge rather than per vertex: the edge, not the resource alone, is the fact this
   * graph exists to show, so the table reads the same relationship the chart draws. */
  protected readonly tableRows = computed<readonly ProvenanceTableRow[]>(() => {
    const { vertices, edges } = this.graph();
    const byID = new Map(vertices.map((vertex) => [vertex.id, vertex] as const));

    return edges
      .flatMap((edge) => {
        const source = byID.get(edge.source);
        const target = byID.get(edge.target);
        return source && target
          ? [
              {
                id: `${edge.source}~${edge.target}`,
                sourceResourceID: source.resourceID,
                sourceName: source.label,
                sourcePlatform: source.platform,
                targetResourceID: target.resourceID,
                targetName: target.label,
                targetPlatform: target.platform,
              },
            ]
          : [];
      })
      .sort(
        (a, b) => a.sourceName.localeCompare(b.sourceName) || a.targetName.localeCompare(b.targetName),
      );
  });

  protected readonly clusters = computed<readonly ProvenanceCluster[]>(() => {
    const { vertices, edges } = this.graph();
    return buildProvenanceClusters(vertices, edges);
  });

  /** Registries actually present, in canonical order — drives both the legend and every node's
   * accent colour, so a registry can never wear one hue in the legend and another on its node. */
  protected readonly legendPlatforms = computed<readonly Platform[]>(() => {
    const palette = this.paletteService.palette();
    return provenancePlatformColorScale(this.graph().vertices, palette).domain;
  });

  protected selectResource(resourceID: string): void {
    this.resourceSelect.emit(resourceID);
  }

  /** Registry identity, not chart rank — see `provenancePlatformColorScale`. Resolved through
   * `ChartPaletteService` rather than a bare CSS token so the value is guaranteed to repaint
   * whenever `ThemeStore.isDark()` flips, the same guarantee every other chart in this directory
   * relies on. */
  protected colorFor(platform: Platform): string {
    return this.paletteService.palette().platforms[platform];
  }

  /** A single sentence naming everything one card groups together, so a screen reader announces
   * the relationship the border and the "Also registered as" caption otherwise convey visually. */
  protected clusterLabel(cluster: ProvenanceCluster): string {
    const others = cluster.spokes.map(
      (spoke) => `${spoke.label} (${platformLabel(spoke.platform)})`,
    );
    if (cluster.overflowCount > 0) {
      others.push(`${cluster.overflowCount} more in the table below`);
    }
    return others.length > 0
      ? `${cluster.hub.label}, also registered as ${others.join(', ')}`
      : cluster.hub.label;
  }
}

/**
 * Nodes are resources; edges are the provenance links Patra recorded between them.
 *
 * A resource contributes a node only once it takes part in an edge — either because its own
 * `links` names another resource, or because some other resource's `links` names it. A resource
 * with no cross-registry link plays no part in this graph, which today is every resource: the
 * collector that populates `links` runs in a later task, so an empty result here is expected,
 * not a sign anything is broken.
 *
 * Building one node per distinct resource id — rather than one node per link — is what turns the
 * CAN Benchmark's two links (datasheet→GitHub, datasheet→Hugging Face) into one three-node
 * cluster instead of two disconnected pairs each with their own copy of the datasheet.
 */
export function buildProvenanceGraph(
  resources: readonly Resource[],
  resourcePlatform: ReadonlyMap<string, Platform>,
): { vertices: readonly ProvenanceGraphVertex[]; edges: readonly ProvenanceGraphEdge[] } {
  const verticesByID = new Map<string, ProvenanceGraphVertex>();
  // Which ids actually ended up on one end of a real edge. Built separately from
  // `verticesByID` because `ensureVertex` has to resolve the source *before* it knows whether
  // any of that resource's links will themselves resolve — a resource whose only link named an
  // unidentifiable target must not leave behind an edgeless island node.
  const referencedIDs = new Set<string>();
  const edges: ProvenanceGraphEdge[] = [];
  const seenEdgeKeys = new Set<string>();

  const ensureVertex = (
    id: string | undefined,
    name: string | undefined,
    platform: Platform | undefined,
  ): ProvenanceGraphVertex | null => {
    if (!id || !platform) {
      return null;
    }
    const existing = verticesByID.get(id);
    if (existing) {
      return existing;
    }
    const vertex = makeVertex(id, name ?? id, platform);
    verticesByID.set(id, vertex);
    return vertex;
  };

  for (const resource of resources) {
    const links = resource.links;
    if (!links || links.length === 0) {
      continue;
    }

    const source = ensureVertex(resource.id, resource.name, resourcePlatform.get(resource.id ?? ''));
    if (!source) {
      continue;
    }

    for (const linked of links) {
      const target = ensureVertex(linked.id, linked.name, linked.platform);
      if (!target || target.id === source.id) {
        continue;
      }

      // Undirected identity: a link is the same edge whichever side it was recorded on, so two
      // resources that each name the other still draw as one edge, not two stacked on top of it.
      const edgeKey = [source.id, target.id].sort().join('~');
      if (seenEdgeKeys.has(edgeKey)) {
        continue;
      }
      seenEdgeKeys.add(edgeKey);
      edges.push({ source: source.id, target: target.id });
      referencedIDs.add(source.id);
      referencedIDs.add(target.id);
    }
  }

  const vertices = [...referencedIDs].flatMap((id) => {
    const vertex = verticesByID.get(id);
    return vertex ? [vertex] : [];
  });

  return { vertices, edges };
}

/**
 * Groups vertices into the connected components the edge list already implies — distinct
 * artifacts never share an edge (see `buildProvenanceGraph`), so grouping by component is
 * grouping by artifact, no different from what `forceLayout`'s own repulsion used to do
 * implicitly and unreliably. Union-find makes that grouping a pure, order-independent function of
 * the data: the same vertices and edges always fold into the same components, in the same
 * membership, no matter what order they arrive in.
 *
 * Within a component, the hub is whichever vertex touches the most edges. In every case the real
 * backend produces today that is unambiguous: only the Patra-side resource ever owns a `links`
 * entry (see `buildProvenanceGraph`'s doc comment), so it is the only vertex that can have more
 * than one edge in a star-shaped cluster. A perfectly symmetric pair (each resource naming only
 * the other) has no such vertex, so the tie there — and any other tie — breaks on label, then id,
 * so the choice never depends on object or Map iteration order.
 *
 * Clusters themselves are returned in a stable order (alphabetical by hub name) for the same
 * reason: the grid reads left-to-right, top-to-bottom, and that reading order must not shuffle
 * between renders of the same catalog.
 */
export function buildProvenanceClusters(
  vertices: readonly ProvenanceGraphVertex[],
  edges: readonly ProvenanceGraphEdge[],
): readonly ProvenanceCluster[] {
  if (vertices.length === 0) {
    return [];
  }

  const parent = new Map<string, string>(vertices.map((vertex) => [vertex.id, vertex.id]));
  const find = (id: string): string => {
    let root = id;
    while (parent.get(root) !== root) {
      root = parent.get(root) as string;
    }
    let current = id;
    while (parent.get(current) !== root) {
      const next = parent.get(current) as string;
      parent.set(current, root);
      current = next;
    }
    return root;
  };
  for (const edge of edges) {
    const rootA = find(edge.source);
    const rootB = find(edge.target);
    if (rootA !== rootB) {
      parent.set(rootB, rootA);
    }
  }

  const degree = new Map<string, number>();
  for (const edge of edges) {
    degree.set(edge.source, (degree.get(edge.source) ?? 0) + 1);
    degree.set(edge.target, (degree.get(edge.target) ?? 0) + 1);
  }

  const membersByRoot = new Map<string, ProvenanceGraphVertex[]>();
  for (const vertex of vertices) {
    const root = find(vertex.id);
    const members = membersByRoot.get(root);
    if (members) {
      members.push(vertex);
    } else {
      membersByRoot.set(root, [vertex]);
    }
  }

  const byRank = (a: ProvenanceGraphVertex, b: ProvenanceGraphVertex): number =>
    a.label.localeCompare(b.label) || a.id.localeCompare(b.id);

  const clusters = [...membersByRoot.values()].map((members): ProvenanceCluster => {
    const [hub, ...rest] = [...members].sort(
      (a, b) => (degree.get(b.id) ?? 0) - (degree.get(a.id) ?? 0) || byRank(a, b),
    );
    const spokes = rest.sort(byRank);
    return {
      id: hub.id,
      hub,
      spokes: spokes.slice(0, MAX_VISIBLE_SPOKES),
      overflowCount: Math.max(0, spokes.length - MAX_VISIBLE_SPOKES),
    };
  });

  return clusters.sort((a, b) => byRank(a.hub, b.hub));
}

/**
 * Domain/range pair naming one swatch per platform actually present in the graph, pulled from
 * the palette's registry-identity tokens rather than a chart-rank slot.
 *
 * Exported so the colour assignment is directly testable without standing up the whole component,
 * and reused inside it to build the legend and every node's accent from one shared list, so a
 * registry can never wear two different hues on one screen.
 */
export function provenancePlatformColorScale(
  vertices: readonly ProvenanceGraphVertex[],
  palette: Pick<ChartPalette, 'platforms'>,
): { readonly domain: readonly Platform[]; readonly range: readonly string[] } {
  const present = new Set(vertices.map((vertex) => vertex.platform));
  const domain = PLATFORM_ORDER.filter((platform) => present.has(platform));
  return { domain, range: domain.map((platform) => palette.platforms[platform]) };
}

function makeVertex(id: string, name: string, platform: Platform): ProvenanceGraphVertex {
  return {
    id,
    resourceID: id,
    label: name,
    platform,
    lines: [name, `(${platformLabel(platform)})`],
  };
}
