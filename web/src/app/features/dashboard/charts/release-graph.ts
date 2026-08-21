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
import { defineChart, dot, link, text, type ChartPoint } from '@tanstack/charts';
import { Chart } from '@tanstack/charts/angular';
import {
  treeLayout,
  type TreeLayoutLink,
  type TreeLayoutNode,
} from '@tanstack/charts/hierarchy/tree';
import { decorative } from '@tanstack/charts/mark/decorative';
import { scaleLinear } from '@tanstack/charts/scales/linear';
import { tooltip } from '@tanstack/charts/tooltip';

import type { Release, Resource } from '../../../core/api/models';
import { ChartFigure } from '../../../shared/charts/chart-figure';
import { formatDate } from '../../../shared/format/formatters';
import { ChartPaletteService } from '../../../shared/charts/chart-palette';
import { parseReleaseVersion } from '../../releases/release-version';

interface ReleaseGraphNode {
  readonly id: string;
  readonly parentId: string | null;
  readonly label: string;
  readonly resourceID: string | null;
  readonly kind: 'portfolio' | 'resource' | 'release';
  readonly group: string;
  readonly version: string | null;
  readonly releasedAt: string | null;
}

interface ReleaseGraphLink {
  readonly source: string;
  readonly target: string;
}

const MAX_RESOURCES = 10;
const MAX_RELEASES_PER_RESOURCE = 6;
const DAY = 24 * 60 * 60 * 1_000;

interface LineageNode extends TreeLayoutNode<ReleaseGraphNode> {
  readonly x: number;
}

interface LineageLink extends TreeLayoutLink<ReleaseGraphNode> {
  readonly x1: number;
  readonly x2: number;
}

/** Time-scaled release lineage over a bounded set of resources and releases. */
@Component({
  selector: 'app-release-graph',
  imports: [Chart, ChartFigure],
  template: `
    <app-chart-figure heading="Release lineage" [subtitle]="subtitle()">
      <div actions class="ins-release-graph__controls">
        <label class="ins-eyebrow" for="release-graph-resource">Resource</label>
        <select
          id="release-graph-resource"
          [value]="resourceFilter()"
          (change)="selectGraphResource($event)"
        >
          <option value="all">Released resources</option>
          @for (resource of releasedResources(); track resource.id) {
            <option [value]="resource.id">{{ resource.name }}</option>
          }
        </select>
        <span class="ins-release-graph__hint">Select a node to focus its resource</span>
      </div>

      <tanstack-chart chart [options]="chartOptions()" />

      <table table class="ins-chart-table">
        <caption class="ins-visually-hidden">
          Release nodes represented in the graph, newest first. Selecting a resource name scopes the
          full dashboard to it.
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
      max-width: 17rem;
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

  protected readonly releasedResources = computed(() => {
    const released = new Set(this.releases().map((release) => release.resourceID));
    return this.resources()
      .flatMap((resource) =>
        resource.id && released.has(resource.id)
          ? [{ id: resource.id, name: resource.name ?? resource.id }]
          : [],
      )
      .sort((a, b) => a.name.localeCompare(b.name));
  });

  protected readonly resourceFilter = linkedSignal<readonly string[], string | 'all'>({
    source: () => this.releasedResources().map((resource) => resource.id),
    computation: (resourceIDs, previous) =>
      previous && (previous.value === 'all' || resourceIDs.includes(previous.value))
        ? previous.value
        : 'all',
  });

  protected readonly tableReleases = computed(() => {
    const selected = this.resourceFilter();
    return [...this.releases()]
      .filter((release) => selected === 'all' || release.resourceID === selected)
      .sort((a, b) => Date.parse(b.releasedAt ?? '') - Date.parse(a.releasedAt ?? ''));
  });

  private readonly topology = computed(() =>
    buildReleaseTopology(this.tableReleases(), this.resources(), this.resourceFilter()),
  );

  protected readonly subtitle = computed(() => {
    const topology = this.topology();
    const omitted = this.tableReleases().length - topology.releaseCount;
    const suffix = omitted > 0 ? ` · ${omitted} older releases remain in the data table` : '';
    return `${topology.resourceCount} ${topology.resourceCount === 1 ? 'resource' : 'resources'} · ${topology.releaseCount} ${topology.releaseCount === 1 ? 'release node' : 'release nodes'}${suffix}`;
  });

  protected readonly chartOptions = computed(() => {
    const palette = this.paletteService.palette();
    const topology = this.topology();
    const colors = palette.series;

    const hierarchy = treeLayout(topology.nodes, {
      id: 'id',
      parentId: 'parentId',
      orientation: 'left',
      nodeSize: [1, 1],
      sort: (a, b) => a.name.localeCompare(b.name),
    });

    const dated = dateLineage(hierarchy.nodes, hierarchy.links);
    const nodes = dated.nodes.filter((node) => node.data?.kind !== 'portfolio');
    const visibleNodeIDs = new Set(nodes.map((node) => node.id));
    const links = dated.links.filter(
      (edge) => visibleNodeIDs.has(edge.source) && visibleNodeIDs.has(edge.target),
    );
    return this.definitionForTree(nodes, links, colors);
  });

  protected selectGraphResource(event: Event): void {
    this.resourceFilter.set((event.target as HTMLSelectElement).value);
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

  private definitionForTree(
    nodes: readonly LineageNode[],
    links: readonly LineageLink[],
    colors: readonly string[],
  ) {
    const palette = this.paletteService.palette();
    const singleResource =
      new Set(nodes.flatMap((node) => (node.data?.resourceID ? [node.data.resourceID] : [])))
        .size === 1;
    const releaseCount = nodes.filter((node) => node.data?.kind === 'release').length;
    const compactSingle = singleResource && releaseCount === 1;
    const plottedNodes = singleResource ? nodes.map((node) => ({ ...node, y: 0 })) : nodes;
    const plottedLinks = singleResource ? links.map((edge) => ({ ...edge, y1: 0, y2: 0 })) : links;
    const yValues = plottedNodes.map((node) => node.y);
    const yMinimum = Math.min(...yValues);
    const yMaximum = Math.max(...yValues);
    const yPadding = yMinimum === yMaximum ? 1 : Math.max(0.55, (yMaximum - yMinimum) * 0.08);
    const xValues = nodes.map((node) => node.x);
    const xMinimum = Math.min(...xValues);
    const xMaximum = Math.max(...xValues);
    const xSpan = Math.max(xMaximum - xMinimum, DAY);
    const xPadding = compactSingle
      ? Math.max(xSpan * 1.25, 21 * DAY)
      : Math.max(xSpan * 0.035, 7 * DAY);
    const nodeRadius = (node: LineageNode): number => {
      if (singleResource) {
        return node.data?.kind === 'resource' ? 13 : 10;
      }
      return node.data?.kind === 'resource' ? 9 : 7;
    };

    return {
      definition: defineChart(
        {
          marks: [
            decorative(
              link(plottedLinks, {
                id: 'release-lineage-links',
                x1: 'x1',
                y1: 'y1',
                x2: 'x2',
                y2: 'y2',
                key: 'id',
                stroke: palette.axis,
                strokeOpacity: singleResource ? 0.75 : 0.6,
                strokeWidth: singleResource ? 2.6 : 1.9,
              }),
            ),
            dot(plottedNodes, {
              id: 'release-lineage-nodes',
              x: 'x',
              y: 'y',
              key: 'id',
              color: (node) => node.data?.group ?? 'portfolio',
              r: nodeRadius,
              stroke: palette.surface,
              strokeWidth: singleResource ? 3 : 2.5,
              states: [
                {
                  when: { focus: 'group' },
                  style: { r: singleResource ? 14 : 10, strokeWidth: 3.25 },
                },
                {
                  when: { focus: 'primary' },
                  style: { r: singleResource ? 15 : 11, strokeWidth: 3.75 },
                },
              ],
            }),
            decorative(
              text(plottedNodes, {
                id: 'release-lineage-labels',
                x: 'x',
                y: 'y',
                key: 'id',
                text: (node) => graphLabel(node.data, this.resourceFilter(), compactSingle),
                dx: singleResource ? 12 : 9,
                dy: (node) => (singleResource || node.data?.kind === 'resource' ? -15 : 0),
                anchor: 'start',
                fill: palette.ink,
                fontSize: singleResource ? 15 : 12,
                fontWeight: singleResource ? 700 : 600,
              }),
            ),
          ],
          x: {
            scale: scaleLinear().domain([xMinimum - xPadding, xMaximum + xPadding]),
            axis: compactSingle
              ? false
              : {
                  line: false,
                  ticks: { count: 5, size: 0, padding: 8, format: formatGraphDate },
                },
            grid: !compactSingle,
          },
          y: {
            scale: scaleLinear().domain([yMinimum - yPadding, yMaximum + yPadding]),
            axis: false,
            grid: false,
          },
          color: { range: colors },
          theme: {
            background: 'transparent',
            foreground: palette.inkSecondary,
            muted: palette.muted,
            grid: palette.grid,
            palette: colors,
          },
          margin: {
            top: singleResource ? 32 : 20,
            right: singleResource ? 150 : 110,
            bottom: compactSingle ? 20 : 38,
            left: 18,
          },
        },
        this.interactions(),
      ),
      ariaLabel: 'Release lineage tree',
      ariaDescription: `${this.subtitle()}. Use arrow keys to inspect nodes and Enter to focus the lineage on that resource.`,
      height: this.chartHeight(),
      onSelect: (point: ChartPoint<unknown> | null) => this.selectPoint(point),
    };
  }

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

  private interactions() {
    return {
      keyboard: true,
      focus: 'nearest' as const,
      focusRing: false,
      maxFocusDistance: Number.POSITIVE_INFINITY,
      tooltip: {
        use: tooltip,
        format: (point: ChartPoint<unknown>) =>
          this.releaseNodeTooltip(releaseNodeFromPoint(point.datum)),
      },
    };
  }

  private selectPoint(point: ChartPoint<unknown> | null): void {
    const datum = releaseNodeFromPoint(point?.datum);
    if (datum?.resourceID) {
      this.resourceFilter.set(datum.resourceID);
    }
  }

  private releaseNodeTooltip(node: ReleaseGraphNode | null): string {
    if (!node) {
      return 'Release lineage';
    }
    if (node.kind === 'resource') {
      return `${node.label} · Select to focus this resource`;
    }

    const resource = node.resourceID ? this.resourceName(node.resourceID) : 'Unknown resource';
    const date = node.releasedAt ? ` · ${formatDate(node.releasedAt)}` : '';
    return `${resource} · ${node.label}${date}`;
  }
}

function buildReleaseTopology(
  releases: readonly Release[],
  resources: readonly Resource[],
  selected: string | 'all',
): {
  readonly nodes: readonly ReleaseGraphNode[];
  readonly links: readonly ReleaseGraphLink[];
  readonly resourceCount: number;
  readonly releaseCount: number;
} {
  const names = new Map(
    resources.flatMap((resource) =>
      resource.id ? [[resource.id, resource.name ?? resource.id] as const] : [],
    ),
  );
  const byResource = new Map<string, Release[]>();
  for (const release of releases) {
    if (!release.resourceID || (selected !== 'all' && release.resourceID !== selected)) {
      continue;
    }
    const group = byResource.get(release.resourceID) ?? [];
    group.push(release);
    byResource.set(release.resourceID, group);
  }

  const resourceGroups = [...byResource]
    .map(([resourceID, rows]) => ({
      resourceID,
      rows: rows.sort((a, b) => Date.parse(a.releasedAt ?? '') - Date.parse(b.releasedAt ?? '')),
      latest: Math.max(...rows.map((row) => Date.parse(row.releasedAt ?? '') || 0)),
    }))
    .sort((a, b) => b.latest - a.latest)
    .slice(0, selected === 'all' ? MAX_RESOURCES : 1);

  const nodes: ReleaseGraphNode[] = [
    {
      id: 'release-portfolio',
      parentId: null,
      label: '',
      resourceID: null,
      kind: 'portfolio',
      group: 'portfolio',
      version: null,
      releasedAt: null,
    },
  ];
  const links: ReleaseGraphLink[] = [];
  let releaseCount = 0;

  for (const group of resourceGroups) {
    const resourceNodeID = `resource-${group.resourceID}`;
    nodes.push({
      id: resourceNodeID,
      parentId: 'release-portfolio',
      label: names.get(group.resourceID) ?? group.resourceID,
      resourceID: group.resourceID,
      kind: 'resource',
      group: group.resourceID,
      version: null,
      releasedAt: null,
    });
    links.push({ source: 'release-portfolio', target: resourceNodeID });

    let parentId = resourceNodeID;
    const visibleRows = group.rows.slice(-MAX_RELEASES_PER_RESOURCE);
    for (const [index, release] of visibleRows.entries()) {
      const id = `release-${release.id ?? `${group.resourceID}-${index}`}`;
      const parsed = parseReleaseVersion(release.version);
      nodes.push({
        id,
        parentId,
        label: release.version ?? 'Unlabelled',
        resourceID: group.resourceID,
        kind: 'release',
        group: parsed.kind === 'semver' ? `major-${parsed.major}` : group.resourceID,
        version: release.version ?? null,
        releasedAt: release.releasedAt ?? null,
      });
      links.push({ source: parentId, target: id });
      parentId = id;
      releaseCount += 1;
    }
  }

  return { nodes, links, resourceCount: resourceGroups.length, releaseCount };
}

/**
 * Keeps the tidy tree's stable vertical lanes while replacing its depth coordinate with time.
 *
 * A plain tidy tree gives every release the same horizontal step, which would make a two-day
 * gap look identical to a two-year gap. The transformed x coordinate preserves the hierarchy
 * on y and makes publication date the quantitative x-axis. Resource and portfolio anchors sit
 * just before the earliest visible release so their connector lines remain legible.
 */
function dateLineage(
  nodes: readonly TreeLayoutNode<ReleaseGraphNode>[],
  links: readonly TreeLayoutLink<ReleaseGraphNode>[],
): { readonly nodes: readonly LineageNode[]; readonly links: readonly LineageLink[] } {
  const dates = nodes.flatMap((node) => {
    const time = Date.parse(node.data?.releasedAt ?? '');
    return Number.isFinite(time) ? [time] : [];
  });
  const minimum = dates.length > 0 ? Math.min(...dates) : Date.UTC(2000, 0, 1);
  const maximum = dates.length > 0 ? Math.max(...dates) : minimum;
  const anchorStep = Math.max((maximum - minimum) * 0.06, 21 * DAY);

  const datedNodes = nodes.map((node): LineageNode => {
    const releaseTime = Date.parse(node.data?.releasedAt ?? '');
    const x =
      node.data?.kind === 'release' && Number.isFinite(releaseTime)
        ? releaseTime
        : node.data?.kind === 'resource'
          ? minimum - anchorStep
          : minimum - anchorStep * 2;
    return { ...node, x };
  });
  const xByID = new Map(datedNodes.map((node) => [node.id, node.x] as const));
  const datedLinks = links.map((edge): LineageLink => ({
    ...edge,
    x1: xByID.get(edge.source) ?? edge.x1,
    x2: xByID.get(edge.target) ?? edge.x2,
  }));

  return { nodes: datedNodes, links: datedLinks };
}

function graphLabel(
  node: ReleaseGraphNode | null | undefined,
  selected: string | 'all',
  showReleaseDate: boolean,
): string {
  if (!node) {
    return '';
  }
  if (node.kind === 'portfolio') {
    return '';
  }
  if (node.kind === 'resource') {
    return node.label;
  }
  if (selected !== 'all') {
    return showReleaseDate && node.releasedAt
      ? `${node.label} · ${formatDate(node.releasedAt)}`
      : node.label;
  }
  return '';
}

function releaseNodeFromPoint(datum: unknown): ReleaseGraphNode | null {
  if (typeof datum !== 'object' || datum === null) {
    return null;
  }
  if ('data' in datum) {
    const data = (datum as { data?: unknown }).data;
    return isReleaseGraphNode(data) ? data : null;
  }
  return isReleaseGraphNode(datum) ? datum : null;
}

function isReleaseGraphNode(value: unknown): value is ReleaseGraphNode {
  return typeof value === 'object' && value !== null && 'kind' in value && 'label' in value;
}

const GRAPH_DATE = new Intl.DateTimeFormat('en-US', {
  month: 'short',
  year: 'numeric',
  timeZone: 'UTC',
});

function formatGraphDate(value: number): string {
  return GRAPH_DATE.format(new Date(value));
}
