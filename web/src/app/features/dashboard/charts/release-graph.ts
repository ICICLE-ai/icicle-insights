import {
  Component,
  DestroyRef,
  ElementRef,
  afterNextRender,
  computed,
  inject,
  input,
  linkedSignal,
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

import type { Release, Resource } from '../../../core/api/models';
import { ChartFigure } from '../../../shared/charts/chart-figure';
import { formatDate } from '../../../shared/format/formatters';
import { ChartPaletteService } from '../../../shared/charts/chart-palette';

/** One vertex in a release-period cluster: either the period hub or one resource in it. */
export interface ReleaseGraphVertex {
  readonly id: string;
  readonly kind: 'period' | 'resource';
  readonly isHub: boolean;
  readonly label: string;
  readonly resourceID: string | null;
  readonly version: string | null;
  readonly releasedAt: string | null;
  readonly lines: readonly string[];
  readonly width: number;
  readonly height: number;
  /** Radius of the circle that exactly circumscribes the wrapped-text block — the block's own
   * corners touch the circle, so text sized against `width`/`height` is guaranteed to fit. */
  readonly radius: number;
}

export interface ReleaseGraphEdge {
  readonly source: string;
  readonly target: string;
  readonly distanceHint: number;
}

/** A vertex after layout: adds the settled centre point the `dot` mark needs. */
interface PlacedVertex extends ReleaseGraphVertex {
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

const MAX_CLUSTER_NODES = 10;
const MIN_NODES_FOR_FORCE = 3;
const MAX_LABEL_LINES = 3;
const LINE_HEIGHT_RATIO = 1.2;

const HUB_SIZE = { width: 140, fontSize: 15, fontWeight: 700, paddingX: 14, paddingY: 10 };
const PEER_SIZE = { width: 118, fontSize: 12, fontWeight: 650, paddingX: 12, paddingY: 8 };

/**
 * Who shipped in the same release period: pick a period (`YYYY-MM`), see every resource that
 * released something in it, clustered around a hub for that period rather than around any one
 * of the resources — a period has no natural "lead" resource, so nothing should look like one.
 *
 * Position is physics-only here — `forceLayout` settles a one-shot d3-force simulation with no
 * quantitative meaning in the result. "When" already lives in the hub's own label and, per
 * resource, in the hover tooltip and the paired table.
 */
@Component({
  selector: 'app-release-graph',
  imports: [Chart, ChartFigure],
  template: `
    <app-chart-figure heading="Release cluster" [subtitle]="subtitle()">
      <div actions class="ins-release-graph__controls">
        <label class="ins-eyebrow" for="release-graph-period">Release</label>
        <select
          id="release-graph-period"
          [value]="selectedPeriod()"
          (change)="selectPeriod($event)"
        >
          @for (period of periodOptions(); track period) {
            <option [value]="period">{{ period }}</option>
          }
        </select>
        <span class="ins-release-graph__hint">Select a resource to view its dashboard</span>
      </div>

      <tanstack-chart chart [options]="chartOptions()" />

      <table table class="ins-chart-table">
        <caption class="ins-visually-hidden">
          Every release from
          {{
            selectedPeriod()
          }}, newest first. Selecting a resource name scopes the full dashboard to it.
        </caption>
        <thead>
          <tr>
            <th scope="col">Resource</th>
            <th scope="col">Version</th>
            <th scope="col">Released</th>
          </tr>
        </thead>
        <tbody>
          @for (release of tableReleases(); track release.id ?? $index) {
            <tr>
              <th scope="row">
                <button
                  type="button"
                  class="ins-release-graph__resource-link"
                  (click)="selectDashboardResource(release.resourceID)"
                >
                  {{ resourceName(release.resourceID) }}
                </button>
              </th>
              <td class="ins-mono">{{ release.version || 'Unlabelled' }}</td>
              <td>{{ when(release.releasedAt) }}</td>
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

    .ins-release-graph__controls {
      display: flex;
      align-items: center;
      flex-wrap: wrap;
      gap: 0.5rem;
    }

    .ins-release-graph__controls select {
      max-width: 22rem;
      min-height: 2.375rem;
      padding: 0.3125rem 1.75rem 0.3125rem 0.5rem;
      color: var(--ins-ink);
      background: var(--ins-surface);
      border: 1px solid var(--ins-border);
      border-radius: var(--ins-radius-sm);
      font: inherit;
      font-size: var(--ins-text-small);
    }

    .ins-release-graph__hint {
      color: var(--ins-ink-muted);
      font-size: var(--ins-text-micro);
      white-space: nowrap;
    }

    .ins-release-graph__resource-link {
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
export class ReleaseGraph {
  readonly releases = input.required<readonly Release[]>();
  readonly resources = input.required<readonly Resource[]>();
  readonly resourceSelect = output<string>();

  private readonly paletteService = inject(ChartPaletteService);
  private readonly host: ElementRef<HTMLElement> = inject(ElementRef);
  private readonly destroyRef = inject(DestroyRef);
  protected readonly when = (value: string | undefined) =>
    value ? formatDate(value) : 'Unknown date';
  protected readonly chartHeight = signal(420);

  protected readonly periodOptions = computed(() => {
    const periods = new Set<string>();
    for (const release of this.releases()) {
      const time = Date.parse(release.releasedAt ?? '');
      if (release.resourceID && Number.isFinite(time)) {
        periods.add(monthKey(time));
      }
    }
    return [...periods].sort((a, b) => b.localeCompare(a));
  });

  protected readonly selectedPeriod = linkedSignal<readonly string[], string>({
    source: () => this.periodOptions(),
    computation: (periods, previous) =>
      previous && periods.includes(previous.value) ? previous.value : (periods[0] ?? ''),
  });

  private readonly cluster = computed(() =>
    buildReleaseCluster(this.releases(), this.resources(), this.selectedPeriod()),
  );

  protected readonly tableReleases = computed(() =>
    [...this.cluster().periodReleases].sort(
      (a, b) => Date.parse(b.releasedAt ?? '') - Date.parse(a.releasedAt ?? ''),
    ),
  );

  protected readonly subtitle = computed(() => {
    const cluster = this.cluster();
    const count = cluster.vertices.filter((vertex) => vertex.kind === 'resource').length;
    if (count === 0) {
      return 'No releases recorded for this selection.';
    }
    const suffix =
      cluster.omittedCount > 0
        ? ` · ${cluster.omittedCount} more from ${this.selectedPeriod()} in the data table`
        : '';
    return `${count} ${count === 1 ? 'resource' : 'resources'} · ${this.selectedPeriod()}${suffix}`;
  });

  protected readonly chartOptions = computed(() => {
    const palette = this.paletteService.palette();
    const { vertices, edges } = this.cluster();
    const layout = layoutCluster(vertices, edges);
    return definitionForCluster(layout, palette, this.chartHeight(), this.selectPoint.bind(this));
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
    const nextHeight = Math.min(960, Math.max(380, available));

    if (nextHeight !== this.chartHeight()) {
      this.chartHeight.set(nextHeight);
    }
  }

  protected selectPeriod(event: Event): void {
    this.selectedPeriod.set((event.target as HTMLSelectElement).value);
  }

  protected selectDashboardResource(resourceID: string | undefined): void {
    if (resourceID) {
      this.resourceSelect.emit(resourceID);
    }
  }

  protected resourceName(resourceID: string | undefined): string {
    return (
      this.resources().find((resource) => resource.id === resourceID)?.name ?? 'Unknown resource'
    );
  }

  /** A click/Enter on a resource vertex scopes the whole dashboard to it — the same action as
   * the paired table's resource-name link. The hub represents the period itself, not a
   * resource, so it has nothing to navigate to. */
  private selectPoint(point: ChartPoint<unknown> | null): void {
    const vertex = releaseVertexFromPoint(point?.datum);
    if (vertex && vertex.kind === 'resource' && vertex.resourceID) {
      this.resourceSelect.emit(vertex.resourceID);
    }
  }
}

/** UTC calendar-month key in `YYYY-MM` form, matching `dashboard.ts`'s `releaseMonths` grouping
 * exactly so this view and the Cadence tab agree on what a "period" is. */
function monthKey(time: number): string {
  const date = new Date(time);
  return `${date.getUTCFullYear()}-${String(date.getUTCMonth() + 1).padStart(2, '0')}`;
}

/** Every distinct resource that released something in the selected period, capped so the graph
 * stays a legible cluster around its hub rather than the whole portfolio. */
export function buildReleaseCluster(
  releases: readonly Release[],
  resources: readonly Resource[],
  selectedPeriod: string,
): {
  readonly vertices: readonly ReleaseGraphVertex[];
  readonly edges: readonly ReleaseGraphEdge[];
  readonly periodReleases: readonly Release[];
  readonly omittedCount: number;
} {
  const empty = { vertices: [], edges: [], periodReleases: [], omittedCount: 0 };
  if (!selectedPeriod) {
    return empty;
  }

  const names = new Map(
    resources.flatMap((resource) =>
      resource.id ? [[resource.id, resource.name ?? resource.id] as const] : [],
    ),
  );

  const periodEntries = releases.flatMap((release) => {
    const time = Date.parse(release.releasedAt ?? '');
    return release.resourceID && Number.isFinite(time) && monthKey(time) === selectedPeriod
      ? [{ release, time }]
      : [];
  });
  if (periodEntries.length === 0) {
    return empty;
  }

  // One entry per resource: that resource's latest release within the period, if it shipped
  // more than once. Kept in a stable, anchor-free order — nothing here is "closer" to anything.
  const byResource = new Map<string, { release: Release; time: number }>();
  for (const entry of periodEntries) {
    const resourceID = entry.release.resourceID;
    if (!resourceID) {
      continue;
    }
    const existing = byResource.get(resourceID);
    if (!existing || entry.time > existing.time) {
      byResource.set(resourceID, entry);
    }
  }

  const candidates = [...byResource.values()].sort((a, b) =>
    (names.get(a.release.resourceID ?? '') ?? '').localeCompare(
      names.get(b.release.resourceID ?? '') ?? '',
    ),
  );
  const kept = candidates.slice(0, MAX_CLUSTER_NODES);
  const omittedCount = candidates.length - kept.length;

  const hubLines = wrapResourceLabel(
    selectedPeriod,
    HUB_SIZE.width - HUB_SIZE.paddingX * 2,
    HUB_SIZE.fontSize,
    MAX_LABEL_LINES,
  );
  const hubHeight = HUB_SIZE.paddingY * 2 + hubLines.length * HUB_SIZE.fontSize * LINE_HEIGHT_RATIO;
  const hub: ReleaseGraphVertex = {
    id: `period-${selectedPeriod}`,
    kind: 'period',
    isHub: true,
    label: selectedPeriod,
    resourceID: null,
    version: null,
    releasedAt: null,
    lines: hubLines,
    width: HUB_SIZE.width,
    height: hubHeight,
    radius: Math.hypot(HUB_SIZE.width / 2, hubHeight / 2),
  };

  const peers: ReleaseGraphVertex[] = kept.map(({ release }) => {
    const resourceID = release.resourceID ?? '';
    const resourceName = names.get(resourceID) ?? resourceID;
    const lines = wrapResourceLabel(
      resourceName,
      PEER_SIZE.width - PEER_SIZE.paddingX * 2,
      PEER_SIZE.fontSize,
      MAX_LABEL_LINES,
    );
    const height = PEER_SIZE.paddingY * 2 + lines.length * PEER_SIZE.fontSize * LINE_HEIGHT_RATIO;
    return {
      id: release.id ?? `${resourceID}-${selectedPeriod}`,
      kind: 'resource',
      isHub: false,
      label: resourceName,
      resourceID,
      version: release.version ?? null,
      releasedAt: release.releasedAt ?? null,
      lines,
      width: PEER_SIZE.width,
      height,
      radius: Math.hypot(PEER_SIZE.width / 2, height / 2),
    };
  });

  const edges: ReleaseGraphEdge[] = peers.map((peer) => ({
    source: hub.id,
    target: peer.id,
    distanceHint: hub.radius + peer.radius + 40,
  }));

  return {
    vertices: [hub, ...peers],
    edges,
    periodReleases: periodEntries.map((entry) => entry.release),
    omittedCount,
  };
}

/** Places a hub with 0–1 peers deterministically (a "simulation" over that few nodes just settles
 * into an arbitrary position), or hands off to `forceLayout` for a real cluster. */
function layoutCluster(
  vertices: readonly ReleaseGraphVertex[],
  edges: readonly ReleaseGraphEdge[],
): LayoutResult {
  if (vertices.length === 0) {
    return { vertices: [], edges: [], xDomain: [-1, 1], yDomain: [-1, 1] };
  }

  if (vertices.length < MIN_NODES_FOR_FORCE) {
    const placed =
      vertices.length === 1
        ? [placeVertex(vertices[0], 0, 0)]
        : [placeVertex(vertices[0], 0, 0), placeVertex(vertices[1], 140, 0)];
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
    return {
      vertices: placed,
      edges: placedEdges,
      xDomain: [-maxRadius - 20, 140 + maxRadius + 20],
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
      { type: 'link', distance: (edge) => edge.distanceHint, strength: 0.55 },
      { type: 'manyBody', strength: -820 },
      { type: 'center', x: 0, y: 0 },
      // Exact rather than approximate now that vertices are circles: two circles just touch
      // when their centres are `radius` apart plus this gap, with no diagonal-vs-edge slop.
      { type: 'collide', radius: (node) => node.radius + 8, strength: 0.9 },
      { type: 'x', x: 0, strength: (node) => (node.isHub ? 0.5 : 0.03) },
      { type: 'y', y: 0, strength: (node) => (node.isHub ? 0.5 : 0.03) },
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

function placeVertex(vertex: ReleaseGraphVertex, x: number, y: number): PlacedVertex {
  return { ...vertex, x, y };
}

function definitionForCluster(
  layout: LayoutResult,
  palette: ReturnType<ChartPaletteService['palette']>,
  chartHeight: number,
  onSelect: (point: ChartPoint<unknown> | null) => void,
) {
  const { vertices, edges, xDomain, yDomain } = layout;
  const peers = vertices.filter((vertex) => !vertex.isHub);
  const hub = vertices.filter((vertex) => vertex.isHub);

  return {
    definition: defineChart(
      {
        marks: [
          decorative(
            link(edges, {
              id: 'release-graph-links',
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
          dot(peers, {
            id: 'release-graph-peer-nodes',
            x: 'x',
            y: 'y',
            r: 'radius',
            key: 'id',
            fill: palette.grid,
            stroke: palette.axis,
            strokeWidth: 1.25,
            states: [
              { when: { focus: 'group' }, style: { strokeWidth: 2.25 } },
              { when: { focus: 'primary' }, style: { strokeWidth: 2.75 } },
            ],
          }),
          ...buildLabelMarks(peers, PEER_SIZE, palette.ink, 'release-graph-peer-label'),
          dot(hub, {
            id: 'release-graph-hub-node',
            x: 'x',
            y: 'y',
            r: 'radius',
            key: 'id',
            fill: palette.ranked[0],
            stroke: palette.ranked[0],
            strokeWidth: 2,
            states: [
              { when: { focus: 'group' }, style: { strokeWidth: 3 } },
              { when: { focus: 'primary' }, style: { strokeWidth: 3.5 } },
            ],
          }),
          ...buildLabelMarks(hub, HUB_SIZE, palette.rankedInk, 'release-graph-hub-label'),
        ],
        x: { scale: scaleLinear().domain(xDomain), axis: false, grid: false },
        y: { scale: scaleLinear().domain(yDomain), axis: false, grid: false },
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
            releaseVertexTooltipContent(releaseVertexFromPoint(points[0]?.datum)),
        },
      },
    ),
    ariaLabel: 'Release graph',
    ariaDescription:
      'A period at the centre, surrounded by every resource that released something in it. ' +
      'Use arrow keys to move between them and Enter to open a resource.',
    height: chartHeight,
    onSelect,
  };
}

/** One mark call per label line, since `text`'s `fontSize`/`fontWeight` are constants, not
 * per-datum channels — splitting hub vs. peer vertices into separate calls (their own,
 * differently-sized groups) is what lets each group have its own type scale. */
function buildLabelMarks(
  vertices: readonly PlacedVertex[],
  size: typeof HUB_SIZE | typeof PEER_SIZE,
  fill: string,
  idPrefix: string,
) {
  const lineHeight = size.fontSize * LINE_HEIGHT_RATIO;
  return Array.from({ length: MAX_LABEL_LINES }, (_, lineIndex) =>
    decorative(
      text(vertices, {
        id: `${idPrefix}-${lineIndex}`,
        x: 'x',
        y: 'y',
        key: 'id',
        text: (vertex: PlacedVertex) => vertex.lines[lineIndex] ?? '',
        dy: (vertex: PlacedVertex) => (lineIndex - (vertex.lines.length - 1) / 2) * lineHeight,
        anchor: 'middle',
        fill,
        fontSize: size.fontSize,
        fontWeight: size.fontWeight,
      }),
    ),
  );
}

/** Estimated width at a 12px reference size, scaled linearly to `fontSizePx` — the same
 * character-class heuristic `top-resources-chart.ts` uses for its own label-fit check. */
function estimateTextWidth(value: string, fontSizePx: number): number {
  const base = [...value].reduce((width, character) => {
    if (/[MW@#%]/u.test(character)) {
      return width + 9;
    }
    if (/[ilI1|.,'`]/u.test(character)) {
      return width + 4;
    }
    return width + 7;
  }, 0);
  return base * (fontSizePx / 12);
}

/** Splits on whitespace and on `-`/`_`/`.` boundaries, keeping the delimiter attached to the
 * token before it — "food-access-model" has break points there; "gnnfoodflowportal" has none. */
function tokenizeLabel(value: string): readonly string[] {
  const tokens: string[] = [];
  let current = '';
  for (const character of value) {
    current += character;
    if (character === ' ' || character === '-' || character === '_' || character === '.') {
      tokens.push(current);
      current = '';
    }
  }
  if (current.length > 0) {
    tokens.push(current);
  }
  return tokens;
}

/** Greedy word-wrap sized against a target box width, hard-breaking a single token that alone
 * exceeds the width, and ellipsizing whatever still doesn't fit after `maxLines`. */
export function wrapResourceLabel(
  name: string,
  maxWidthPx: number,
  fontSizePx: number,
  maxLines: number,
): readonly string[] {
  const tokens = tokenizeLabel(name.trim());
  const lines: string[] = [];
  let current = '';

  const flush = (): void => {
    if (current.length > 0) {
      lines.push(current);
      current = '';
    }
  };

  for (const token of tokens) {
    if (lines.length > maxLines) {
      break;
    }

    if (estimateTextWidth(current + token, fontSizePx) <= maxWidthPx) {
      current += token;
      continue;
    }

    flush();
    if (estimateTextWidth(token, fontSizePx) <= maxWidthPx) {
      current = token;
      continue;
    }

    // A single token wider than the box on its own: hard-break it character by character.
    for (const character of token) {
      if (estimateTextWidth(current + character, fontSizePx) > maxWidthPx) {
        flush();
      }
      current += character;
    }
  }
  flush();

  if (lines.length <= maxLines) {
    return lines.map((line) => line.trim());
  }

  const kept = lines.slice(0, maxLines).map((line) => line.trim());
  kept[maxLines - 1] = ellipsize(kept[maxLines - 1], maxWidthPx, fontSizePx);
  return kept;
}

function ellipsize(line: string, maxWidthPx: number, fontSizePx: number): string {
  let text = line;
  while (text.length > 1 && estimateTextWidth(`${text}…`, fontSizePx) > maxWidthPx) {
    text = text.slice(0, -1);
  }
  return `${text}…`;
}

function releaseVertexFromPoint(datum: unknown): PlacedVertex | null {
  return isPlacedVertex(datum) ? datum : null;
}

function isPlacedVertex(value: unknown): value is PlacedVertex {
  return typeof value === 'object' && value !== null && 'kind' in value && 'isHub' in value;
}

/** A two-row mini table — Version, then Release in `YYYY-MM` — for a resource vertex; just the
 * period name for the hub, which has no version or single release date of its own. */
function releaseVertexTooltipContent(vertex: PlacedVertex | null): ChartTooltipContent {
  if (!vertex) {
    return { rows: [] };
  }
  if (vertex.kind === 'period') {
    return { title: vertex.label, rows: [] };
  }

  const releaseMonth = vertex.releasedAt ? monthKey(Date.parse(vertex.releasedAt)) : '—';
  return {
    title: vertex.label,
    rows: [
      { label: 'Version', value: vertex.version ?? 'Unlabelled' },
      { label: 'Release', value: releaseMonth },
    ],
  };
}
