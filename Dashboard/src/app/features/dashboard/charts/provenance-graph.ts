import {
  Component,
  DestroyRef,
  ElementRef,
  afterNextRender,
  computed,
  inject,
  input,
  output,
  signal,
} from '@angular/core';
import {
  defineChart,
  dot,
  link,
  text,
  type ChartPoint,
  type ChartTooltipContent,
} from '@tanstack/charts';
import { Chart } from '@tanstack/charts/angular';
import { decorative } from '@tanstack/charts/mark/decorative';
import { forceLayout } from '@tanstack/charts/network/force';
import { scaleLinear } from '@tanstack/charts/scales/linear';
import { tooltip } from '@tanstack/charts/tooltip';

import type { Platform, Resource } from '../../../core/api/models';
import { ChartFigure } from '../../../shared/charts/chart-figure';
import { ChartPaletteService, type ChartPalette } from '../../../shared/charts/chart-palette';
import { pluralize } from '../../../shared/format/formatters';
import { PLATFORM_ORDER, platformLabel } from '../../../shared/format/labels';
import { wrapResourceLabel } from './release-graph';

/**
 * One vertex in the provenance graph: a single `Resource` row, positioned by the registry it
 * lives on and joined to every other row Patra recorded as the same real artifact.
 */
export interface ProvenanceGraphVertex {
  readonly id: string;
  readonly resourceID: string;
  readonly label: string;
  readonly platform: Platform;
  readonly lines: readonly string[];
  readonly width: number;
  readonly height: number;
  /** Radius of the circle that exactly circumscribes the wrapped-text block — the block's own
   * corners touch the circle, so text sized against `width`/`height` is guaranteed to fit. */
  readonly radius: number;
}

/** One provenance link: two `Resource` rows a Patra card recorded as the same artifact. */
export interface ProvenanceGraphEdge {
  readonly source: string;
  readonly target: string;
  readonly distanceHint: number;
}

/** A vertex after layout: adds the settled centre point the `dot` mark needs. */
interface PlacedVertex extends ProvenanceGraphVertex {
  readonly x: number;
  readonly y: number;
}

interface PlacedEdge {
  readonly id: string;
  readonly x1: number;
  readonly y1: number;
  readonly x2: number;
  readonly y2: number;
}

interface LayoutResult {
  readonly vertices: readonly PlacedVertex[];
  readonly edges: readonly PlacedEdge[];
  readonly xDomain: readonly [number, number];
  readonly yDomain: readonly [number, number];
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

const MIN_NODES_FOR_FORCE = 3;
const LINE_HEIGHT_RATIO = 1.2;
const NODE_SIZE = { width: 140, fontSize: 12, fontWeight: 650, paddingX: 14, paddingY: 10 };

/**
 * Same artifact, several registries: Patra imports models and datasets that already exist
 * elsewhere, so one real artifact often shows up as several `Resource` rows — the CAN Benchmark
 * is a GitHub repository, a Hugging Face dataset, and a Patra datasheet, three rows for one
 * thing. This graph is what shows a reader that those rows are the same thing.
 *
 * Nodes are resources; edges are the provenance links Patra recorded between them. There is no
 * hub — every node names one registry's copy of the same artifact, so nothing here outranks
 * anything else the way a release period outranks the resources that shipped in it.
 *
 * Position is physics-only, exactly as in the release graph: `forceLayout` settles a one-shot
 * simulation with no quantitative meaning in the result. Distinct artifacts are disjoint in the
 * edge list, so the simulation's own repulsion is what keeps unrelated clusters apart — nothing
 * here has to compute connected components to draw them separately.
 */
@Component({
  selector: 'app-provenance-graph',
  imports: [Chart, ChartFigure],
  template: `
    <app-chart-figure heading="Provenance graph" [subtitle]="subtitle()">
      @if (hasLinks()) {
        <tanstack-chart chart [options]="chartOptions()" />
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
  readonly resources = input.required<readonly Resource[]>();
  /** Resource id → the platform of the account that owns it, from `DashboardStore.catalog()`.
   * Needed because a resource's own platform is not carried on `Resource` itself — only a
   * *link's* platform is, since that comes straight off the DTO. */
  readonly resourcePlatform = input.required<ReadonlyMap<string, Platform>>();
  readonly resourceSelect = output<string>();

  private readonly paletteService = inject(ChartPaletteService);
  private readonly host: ElementRef<HTMLElement> = inject(ElementRef);
  private readonly destroyRef = inject(DestroyRef);

  protected readonly registryLabel = platformLabel;
  protected readonly chartHeight = signal(360);

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

  protected readonly chartOptions = computed(() => {
    const palette = this.paletteService.palette();
    const { vertices, edges } = this.graph();
    const layout = layoutGraph(vertices, edges);
    return definitionForGraph(layout, palette, this.chartHeight(), this.selectPoint.bind(this));
  });

  constructor() {
    afterNextRender(() => {
      if (typeof ResizeObserver === 'undefined') {
        return;
      }

      const observer = new ResizeObserver(() => this.fitChartToViewport());
      observer.observe(this.host.nativeElement);
      this.fitChartToViewport();
      this.destroyRef.onDestroy(() => observer.disconnect());
    });
  }

  /** Uses the open presentation viewport instead of leaving a fixed-height chart in a tall card. */
  private fitChartToViewport(): void {
    const figure = this.host.nativeElement.querySelector<HTMLElement>('.ins-figure');
    const caption = figure?.querySelector<HTMLElement>('.ins-figure__caption');
    const disclosure = figure?.querySelector<HTMLElement>('.ins-figure__data');
    const main = this.host.nativeElement.closest<HTMLElement>('.ins-main');
    const footer = document.querySelector<HTMLElement>('.ins-footer');
    if (!figure || !caption || !disclosure || !main || !footer) {
      return;
    }

    const style = getComputedStyle(figure);
    const mainStyle = getComputedStyle(main);
    const verticalPadding = parseFloat(style.paddingTop) + parseFloat(style.paddingBottom);
    const verticalBorder = parseFloat(style.borderTopWidth) + parseFloat(style.borderBottomWidth);
    const rowGap = parseFloat(style.rowGap || style.gap);
    const chromeHeight =
      verticalPadding +
      caption.getBoundingClientRect().height +
      disclosure.getBoundingClientRect().height +
      rowGap * 2 +
      verticalBorder;
    const hostTop = this.host.nativeElement.getBoundingClientRect().top;
    const contentBottom =
      document.documentElement.clientHeight -
      footer.getBoundingClientRect().height -
      parseFloat(mainStyle.paddingBottom);
    const available = Math.floor(contentBottom - hostTop - chromeHeight);
    const nextHeight = Math.min(960, Math.max(320, available));

    if (nextHeight !== this.chartHeight()) {
      this.chartHeight.set(nextHeight);
    }
  }

  protected selectResource(resourceID: string): void {
    this.resourceSelect.emit(resourceID);
  }

  /** A click/Enter on a node scopes the whole dashboard to that resource — the same action as
   * the paired table's resource-name links. */
  private selectPoint(point: ChartPoint<unknown> | null): void {
    const vertex = provenanceVertexFromPoint(point?.datum);
    if (vertex) {
      this.resourceSelect.emit(vertex.resourceID);
    }
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
      edges.push({
        source: source.id,
        target: target.id,
        distanceHint: source.radius + target.radius + 40,
      });
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
 * Domain/range pair for the chart's colour scale: one swatch per platform actually present in
 * the graph, pulled from the palette's registry-identity tokens rather than a chart-rank slot.
 *
 * `dot`'s own `fill` option is a plain string, not a per-datum channel — the categorical `color`
 * channel plus a chart-level `{domain, range}` scale is the library's mechanism for a colour that
 * varies by field, which is why this exists instead of a function passed straight to `fill`.
 * Exported so the colour assignment is directly testable without standing up a whole chart.
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
  const maxWidth = NODE_SIZE.width - NODE_SIZE.paddingX * 2;
  const nameLine = wrapResourceLabel(name, maxWidth, NODE_SIZE.fontSize, 1)[0] ?? name;
  const platformText = `(${platformLabel(platform)})`;
  const platformLine =
    wrapResourceLabel(platformText, maxWidth, NODE_SIZE.fontSize, 1)[0] ?? platformText;
  const lines = [nameLine, platformLine];
  const height = NODE_SIZE.paddingY * 2 + lines.length * NODE_SIZE.fontSize * LINE_HEIGHT_RATIO;

  return {
    id,
    resourceID: id,
    label: name,
    platform,
    lines,
    width: NODE_SIZE.width,
    height,
    radius: Math.hypot(NODE_SIZE.width / 2, height / 2),
  };
}

/** Places 0–2 vertices deterministically (a "simulation" over that few nodes just settles into
 * an arbitrary position), or hands off to `forceLayout` for a real graph. */
function layoutGraph(
  vertices: readonly ProvenanceGraphVertex[],
  edges: readonly ProvenanceGraphEdge[],
): LayoutResult {
  if (vertices.length === 0) {
    return { vertices: [], edges: [], xDomain: [-1, 1], yDomain: [-1, 1] };
  }

  if (vertices.length < MIN_NODES_FOR_FORCE) {
    const placed =
      vertices.length === 1
        ? [placeVertex(vertices[0], 0, 0)]
        : [placeVertex(vertices[0], -80, 0), placeVertex(vertices[1], 80, 0)];
    const byID = new Map(placed.map((vertex) => [vertex.id, vertex] as const));
    const placedEdges: PlacedEdge[] = edges.flatMap((edge) => {
      const source = byID.get(edge.source);
      const target = byID.get(edge.target);
      return source && target
        ? [
            {
              id: `${edge.source}->${edge.target}`,
              x1: source.x,
              y1: source.y,
              x2: target.x,
              y2: target.y,
            },
          ]
        : [];
    });
    const maxRadius = Math.max(...placed.map((vertex) => vertex.radius), 40);
    const span = placed.length === 2 ? 80 : 0;
    return {
      vertices: placed,
      edges: placedEdges,
      xDomain: [-span - maxRadius - 20, span + maxRadius + 20],
      yDomain: [-maxRadius - 20, maxRadius + 20],
    };
  }

  const graph = forceLayout(vertices, edges, {
    nodeKey: 'id',
    source: 'source',
    target: 'target',
    iterations: 400,
    domainPadding: 0.35,
    forces: [
      { type: 'link', distance: (edge) => edge.distanceHint, strength: 0.6 },
      { type: 'manyBody', strength: -700 },
      { type: 'center', x: 0, y: 0 },
      // Exact rather than approximate now that vertices are circles: two circles just touch
      // when their centres are `radius` apart plus this gap, with no diagonal-vs-edge slop.
      { type: 'collide', radius: (node) => node.radius + 8, strength: 0.9 },
      // Weak and symmetric — unlike the release graph there is no hub to pin near the centre,
      // every node is a peer, so this only keeps a disconnected cluster from drifting off-canvas.
      { type: 'x', x: 0, strength: 0.04 },
      { type: 'y', y: 0, strength: 0.04 },
    ],
  });

  return {
    vertices: graph.nodes.map((node) => placeVertex(node, node.x, node.y)),
    edges: graph.links.map((edge) => ({
      id: `${edge.source}->${edge.target}`,
      x1: edge.x1,
      y1: edge.y1,
      x2: edge.x2,
      y2: edge.y2,
    })),
    xDomain: graph.xDomain,
    yDomain: graph.yDomain,
  };
}

function placeVertex(vertex: ProvenanceGraphVertex, x: number, y: number): PlacedVertex {
  return { ...vertex, x, y };
}

function definitionForGraph(
  layout: LayoutResult,
  palette: ChartPalette,
  chartHeight: number,
  onSelect: (point: ChartPoint<unknown> | null) => void,
) {
  const { vertices, edges, xDomain, yDomain } = layout;
  const colorScale = provenancePlatformColorScale(vertices, palette);

  return {
    definition: defineChart(
      {
        marks: [
          decorative(
            link(edges, {
              id: 'provenance-graph-links',
              x1: 'x1',
              y1: 'y1',
              x2: 'x2',
              y2: 'y2',
              key: 'id',
              stroke: palette.axis,
              strokeOpacity: 0.6,
              strokeWidth: 1.75,
            }),
          ),
          dot(vertices, {
            id: 'provenance-graph-nodes',
            x: 'x',
            y: 'y',
            r: 'radius',
            key: 'id',
            // Registry identity, not chart rank — see `provenancePlatformColorScale`.
            color: 'platform',
            stroke: palette.surface,
            strokeWidth: 1.5,
            states: [
              { when: { focus: 'group' }, style: { strokeWidth: 2.5 } },
              { when: { focus: 'primary' }, style: { strokeWidth: 3 } },
            ],
          }),
          ...buildLabelMarks(vertices, palette.rankedInk),
        ],
        x: { scale: scaleLinear().domain(xDomain), axis: false, grid: false },
        y: { scale: scaleLinear().domain(yDomain), axis: false, grid: false },
        color: colorScale,
        guides: false,
        theme: {
          background: 'transparent',
          foreground: palette.inkSecondary,
          muted: palette.muted,
          grid: palette.grid,
        },
        margin: { top: 24, right: 24, bottom: 24, left: 24 },
      },
      {
        keyboard: true,
        focus: 'nearest',
        focusRing: false,
        maxFocusDistance: Number.POSITIVE_INFINITY,
        tooltip: {
          use: tooltip,
          content: (points: readonly ChartPoint<unknown>[]) =>
            provenanceVertexTooltipContent(provenanceVertexFromPoint(points[0]?.datum)),
        },
      },
    ),
    ariaLabel: 'Provenance graph',
    ariaDescription:
      'Every resource joined to the other registries recorded for the same artifact. ' +
      'Use arrow keys to move between them and Enter to open a resource.',
    height: chartHeight,
    onSelect,
  };
}

/** One mark call per label line: `text`'s `fontSize`/`fontWeight` are constants, not per-datum
 * channels, but every node here shares one size, so — unlike the release graph's hub/peer split
 * — one pair of calls (one per line) covers every vertex. */
function buildLabelMarks(vertices: readonly PlacedVertex[], fill: string) {
  const lineHeight = NODE_SIZE.fontSize * LINE_HEIGHT_RATIO;
  return Array.from({ length: 2 }, (_, lineIndex) =>
    decorative(
      text(vertices, {
        id: `provenance-graph-label-${lineIndex}`,
        x: 'x',
        y: 'y',
        key: 'id',
        text: (vertex: PlacedVertex) => vertex.lines[lineIndex] ?? '',
        dy: (lineIndex - 0.5) * lineHeight,
        anchor: 'middle',
        fill,
        fontSize: NODE_SIZE.fontSize,
        fontWeight: NODE_SIZE.fontWeight,
      }),
    ),
  );
}

function provenanceVertexFromPoint(datum: unknown): PlacedVertex | null {
  return isPlacedVertex(datum) ? datum : null;
}

function isPlacedVertex(value: unknown): value is PlacedVertex {
  return (
    typeof value === 'object' && value !== null && 'resourceID' in value && 'platform' in value
  );
}

/** A one-row tooltip naming the node's registry — the resource's own name is already the chart's
 * title-equivalent via its label lines, so the tooltip only has to add what the label omits. */
function provenanceVertexTooltipContent(vertex: PlacedVertex | null): ChartTooltipContent {
  if (!vertex) {
    return { rows: [] };
  }
  return {
    title: vertex.label,
    rows: [{ label: 'Registry', value: platformLabel(vertex.platform) }],
  };
}
