import type { MetricType, Platform, ResourceType } from '../../core/api/models';

/**
 * Display names, canonical orderings, and entity-stable colour assignment.
 *
 * Kept free of Angular so it can be unit tested directly — these are the functions where a
 * mistake is silent rather than loud.
 */

/** Platform names as each project spells its own. */
const PLATFORM_LABELS: Record<Platform, string> = {
  github: 'GitHub',
  ghcr: 'GHCR',
  huggingface: 'Hugging Face',
  npm: 'npm',
  pypi: 'PyPI',
};

/** A presentation-level collection of registries that users commonly analyze together. */
export type PlatformGroupId = 'repositories' | 'containers' | 'models' | 'packages';

/** The value held by the registry picker. Individual providers remain intact in the API. */
export type PlatformFilter = Platform | PlatformGroupId | 'all';

interface PlatformGroupDefinition {
  readonly id: PlatformGroupId;
  readonly label: string;
  readonly platforms: readonly Platform[];
}

export interface PlatformScopeDefinition {
  readonly value: Platform | PlatformGroupId;
  readonly label: string;
  readonly description: string | null;
  readonly platforms: readonly Platform[];
}

/**
 * Registry groups are deliberately frontend taxonomy, not database values.
 *
 * Every registry belongs to exactly one group, so the pickers name **what a registry publishes**
 * rather than the registry itself: "Containers", not "GHCR". That is the question a reader of
 * this dashboard actually has — how much of the institute's output is models, how much is
 * packages — and it is the only framing under which a multi-registry group like Packages sits
 * beside its neighbours as a peer instead of as the one odd entry in a list of brand names.
 *
 * Membership is what does the work; the labels are presentation. A group that currently holds
 * one registry still reads as its type, so adding a second provider later — a Crates alongside
 * npm, a Quay alongside GHCR — is one entry in this list and changes no component. Every picker
 * count, colour, and filter derives from here rather than repeating `npm || pypi` checks.
 *
 * Splitting "Models & Datasets" into two entries is **not** possible here, and the reason is
 * worth recording: both live on Hugging Face, and this taxonomy keys on the registry. That
 * distinction exists only at the resource level (`ResourceType.model` vs `.dataset`), so it
 * would require the picker to filter by resource type instead — a different dimension, not a
 * longer list.
 *
 * Order sets picker order, and follows `PLATFORM_ORDER` by each group's first member.
 */
export const PLATFORM_GROUPS: readonly PlatformGroupDefinition[] = [
  { id: 'repositories', label: 'Repositories', platforms: ['github'] },
  { id: 'containers', label: 'Containers', platforms: ['ghcr'] },
  { id: 'models', label: 'Models & Datasets', platforms: ['huggingface'] },
  { id: 'packages', label: 'Packages', platforms: ['npm', 'pypi'] },
];

/**
 * Only metrics whose bare name misstates their window need an entry.
 *
 * Hugging Face reports `downloads` over a trailing 30 days and GitHub reports clones and views
 * over a rolling 14 — all three read as lifetime totals if left unqualified, which is the kind
 * of wrong that nobody notices. The `AllTime` twins are derived by suffix in `metricLabel`, so
 * they never need an entry here.
 */
const METRIC_LABELS: Partial<Record<MetricType, string>> = {
  downloads: 'Downloads · 30 days',
  clones: 'Clones · 14 days',
  views: 'Views · 14 days',
};

/**
 * The collection window each qualified metric covers, as a sentence fragment.
 *
 * Exists so a form can put the window in hint text under the picker instead of inside the option
 * label. Dropping the qualifier without saying the window somewhere is the bug `METRIC_LABELS`
 * was written to prevent.
 */
const METRIC_WINDOWS: Partial<Record<MetricType, string>> = {
  downloads: 'a trailing 30 days',
  clones: 'a rolling 14 days',
  views: 'a rolling 14 days',
};

const ALL_TIME_SUFFIX = 'AllTime';

/**
 * Canonical display order for platforms, matching the `Platform` enum.
 *
 * Doubles as the colour-slot assignment: a platform's index here is its series slot, so the
 * colour naming a platform never changes when a filter removes some other platform.
 */
export const PLATFORM_ORDER: readonly Platform[] = ['github', 'ghcr', 'huggingface', 'npm', 'pypi'];

/** Canonical display order for resource types, matching the `ResourceType` enum. */
export const RESOURCE_TYPE_ORDER: readonly ResourceType[] = [
  'container',
  'dataset',
  'model',
  'package',
  'repository',
  'service',
];

/** Uppercases the first character only; the rest is left as the API spelled it. */
const titleCase = (value: string): string => value.charAt(0).toUpperCase() + value.slice(1);

/** Display name for a platform, falling back to the raw value for anything unrecognised. */
export const platformLabel = (platform: string): string =>
  PLATFORM_LABELS[platform as Platform] ?? platform;

/** User-facing name for either Overview, one provider, or a provider group. */
export function platformFilterLabel(filter: PlatformFilter): string {
  if (filter === 'all') {
    return 'Overview';
  }
  return PLATFORM_GROUPS.find((group) => group.id === filter)?.label ?? platformLabel(filter);
}

/** Whether one provider is admitted by the selected registry scope. */
export function platformFilterIncludes(filter: PlatformFilter, platform: Platform): boolean {
  if (filter === 'all') {
    return true;
  }
  const group = PLATFORM_GROUPS.find((candidate) => candidate.id === filter);
  return group ? group.platforms.includes(platform) : filter === platform;
}

/** Whether the picker value names one of the type groups rather than a bare provider. */
export function isPlatformGroup(filter: PlatformFilter): filter is PlatformGroupId {
  return PLATFORM_GROUPS.some((group) => group.id === filter);
}

/**
 * True when the selected scope covers more than one registry.
 *
 * Distinct from `isPlatformGroup`, which every scope now satisfies: with the taxonomy naming
 * types rather than providers, "is this a group?" stopped separating anything, while "am I
 * looking at one registry or several?" is still what a caption needs to know.
 *
 * Answered from the group definition, not from the catalog: the question is what the scope
 * means, and a Packages view is a multi-registry view whether or not a PyPI resource happens to
 * exist today.
 */
export function spansMultipleRegistries(filter: PlatformFilter): boolean {
  const group = PLATFORM_GROUPS.find((candidate) => candidate.id === filter);
  return (group?.platforms.length ?? 0) > 1;
}

/**
 * Builds the visible registry choices in the order providers arrive from the catalog.
 * Group members collapse at the position of their first provider, so adding a member does not
 * require another picker-specific ordering table.
 */
export function platformScopes(platforms: readonly Platform[]): readonly PlatformScopeDefinition[] {
  const present = new Set(platforms);
  const emittedGroups = new Set<PlatformGroupId>();
  const scopes: PlatformScopeDefinition[] = [];

  for (const platform of platforms) {
    const group = PLATFORM_GROUPS.find((candidate) => candidate.platforms.includes(platform));
    if (!group) {
      // Every known provider is grouped, so this is the forward-compatibility path: a provider
      // the API starts returning before `PLATFORM_GROUPS` learns its type still gets a usable
      // scope of its own, under its own name, instead of disappearing from the picker.
      scopes.push({
        value: platform,
        label: platformLabel(platform),
        description: null,
        platforms: [platform],
      });
      continue;
    }
    if (emittedGroups.has(group.id)) {
      continue;
    }

    const members = group.platforms.filter((member) => present.has(member));
    scopes.push({
      value: group.id,
      label: group.label,
      description: members.map(platformLabel).join(' + '),
      platforms: members,
    });
    emittedGroups.add(group.id);
  }

  return scopes;
}

/** Display name for a resource type. */
export const resourceTypeLabel = (type: string): string => titleCase(type);

/**
 * Display name for a metric, qualifying the collection window wherever the bare name would
 * overstate it.
 */
export function metricLabel(type: string): string {
  const explicit = METRIC_LABELS[type as MetricType];
  if (explicit) {
    return explicit;
  }

  if (type.endsWith(ALL_TIME_SUFFIX)) {
    return `${titleCase(type.slice(0, -ALL_TIME_SUFFIX.length))} · all time`;
  }

  return titleCase(type);
}

/**
 * The metric's bare name, with neither collection window nor all-time suffix.
 *
 * Only for pickers, where every option is a metric and the qualifier is repeated noise. Anywhere
 * a *reading* is shown — tables, charts, legends — use `metricLabel`, or a 30-day figure reads as
 * a lifetime total. Pair this with `metricWindowNote` so the window is still on screen.
 *
 * A twin pair reduces to the same string on purpose: `downloads` and `downloadsAllTime` are both
 * "Downloads". Any picker offering both must therefore separate them itself — the dashboard ones
 * group under "Latest window" and "All time" headings — or it will show the option twice.
 */
export const metricBaseLabel = (type: string): string =>
  titleCase(type.endsWith(ALL_TIME_SUFFIX) ? type.slice(0, -ALL_TIME_SUFFIX.length) : type);

/** Sentence describing a metric's collection window, or null when its name is already exact. */
export function metricWindowNote(type: string): string | null {
  const window = METRIC_WINDOWS[type as MetricType];
  return window ? `The platform reports ${type} over ${window}.` : null;
}

/** How many categorical slots the validated palette provides. */
export const SERIES_SLOT_COUNT = 8;

/**
 * The CSS custom property naming a categorical slot.
 *
 * Callers pass the entity's position in a **fixed** ordering, never its rank in the current
 * data. Ranking would repaint every surviving series whenever a filter reordered them, so the
 * colour would encode "third largest right now" instead of naming a thing.
 *
 * Past the eighth slot the palette does not cycle — a ninth hue would collide with one already
 * in use and quietly break the CVD guarantees the ramp was validated for. Callers are expected
 * to cap their series count and fold the tail into "Other"; the neutral returned here is the
 * backstop, not the plan.
 */
export function seriesColor(index: number): string {
  if (index < 0 || index >= SERIES_SLOT_COUNT) {
    return 'var(--ins-ink-muted)';
  }
  return `var(--ins-series-${index + 1})`;
}

/** Series colour for a platform, stable across filter changes. */
export const platformColor = (platform: Platform): string => `var(--ins-platform-${platform})`;

/** Series colour for a resource type, stable across filter changes. */
export const resourceTypeColor = (type: ResourceType): string =>
  seriesColor(RESOURCE_TYPE_ORDER.indexOf(type));
