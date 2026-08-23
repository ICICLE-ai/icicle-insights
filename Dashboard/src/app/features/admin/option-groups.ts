import type { Account, Platform, Resource } from '../../core/api/models';
import { PLATFORM_ORDER, platformLabel, platformScopes } from '../../shared/format/labels';

/**
 * Registry-scope grouping for the admin forms' `<optgroup>` pickers.
 *
 * Two accounts can share a name — "icicle-ai" exists on both GitHub and npm — and so can their
 * resources. A flat list of those is a coin flip. Grouping names the distinction once per group
 * instead of repeating it on every option.
 *
 * Groups follow the same scope taxonomy the dashboard's registry picker uses (`platformScopes`),
 * so npm and PyPI collapse into one "Packages" heading rather than standing apart. That keeps a
 * single vocabulary across the app — but it does re-merge two registries a picker has to tell
 * apart, so options inside a multi-registry group carry their own registry as a suffix. The
 * distinction moves onto the option; it is not lost.
 */

/** One option: the record, plus the text to show for it in its group. */
export interface PlatformOption<T> {
  readonly item: T;
  readonly label: string;
}

/** One `<optgroup>`: a scope heading and the options filed under it. */
export interface PlatformOptionGroup<T> {
  /** Null for the trailing catch-all group. */
  readonly scope: string | null;
  readonly label: string;
  readonly options: readonly PlatformOption<T>[];
}

/** Heading for items whose registry could not be resolved. */
const UNGROUPED_LABEL = 'Unknown registry';

/**
 * Buckets items under their registry scope, in the catalog's canonical platform order.
 *
 * Empty scopes are dropped so a picker never shows a heading with nothing under it. Items whose
 * platform does not resolve are kept in a trailing catch-all rather than filtered out: a
 * resource orphaned from its account is a data problem, and silently omitting it from the picker
 * would hide that problem behind an option that simply is not there.
 */
function groupByPlatformScope<T>(
  items: readonly T[],
  platformOf: (item: T) => Platform | undefined,
  nameOf: (item: T) => string,
): readonly PlatformOptionGroup<T>[] {
  const sorted = [...items].sort((a, b) => nameOf(a).localeCompare(nameOf(b)));
  const present = new Set(sorted.map(platformOf).filter((platform) => platform !== undefined));

  // Canonical order in, canonical order out: `platformScopes` collapses each group at its first
  // member's position, so feeding it `PLATFORM_ORDER` rather than discovery order keeps the
  // headings in the same sequence on every screen regardless of what the catalog holds.
  const scopes = platformScopes(PLATFORM_ORDER.filter((platform) => present.has(platform)));

  const groups = scopes.flatMap<PlatformOptionGroup<T>>((scope) => {
    const members = new Set(scope.platforms);
    const options = sorted
      .filter((item) => {
        const platform = platformOf(item);
        return platform !== undefined && members.has(platform);
      })
      .map((item) => ({
        item,
        // Only qualify inside a group that merges registries — appending "· GitHub" under a
        // heading that already reads "GitHub" is noise.
        label:
          scope.platforms.length > 1
            ? `${nameOf(item)} · ${platformLabel(platformOf(item) as Platform)}`
            : nameOf(item),
      }));

    return options.length > 0
      ? [
          {
            scope: scope.value,
            label: scope.description ? `${scope.label} · ${scope.description}` : scope.label,
            options,
          },
        ]
      : [];
  });

  const ungrouped = sorted.filter((item) => {
    const platform = platformOf(item);
    return platform === undefined || !PLATFORM_ORDER.includes(platform);
  });

  return ungrouped.length > 0
    ? [
        ...groups,
        {
          scope: null,
          label: UNGROUPED_LABEL,
          options: ungrouped.map((item) => ({ item, label: nameOf(item) })),
        },
      ]
    : groups;
}

/**
 * Looks a resource's registry up through its owning account.
 *
 * `Resource` carries only `accountID`; the platform lives on the account. Built once per
 * accounts list rather than searched per resource, so a picker over a large catalog stays a
 * single pass instead of one scan per option.
 */
function resourcePlatformLookup(
  accounts: readonly Account[],
): (resource: Resource) => Platform | undefined {
  const platforms = new Map(
    accounts.flatMap((account) => (account.id ? [[account.id, account.platform]] : [])),
  );
  return (resource) => (resource.accountID ? platforms.get(resource.accountID) : undefined);
}

/** Groups resources under their owning account's registry scope. Records without an id are
 * dropped — a picker option with no value cannot be selected. */
export function groupResourcesByPlatform(
  resources: readonly Resource[],
  accounts: readonly Account[],
): readonly PlatformOptionGroup<Resource>[] {
  const platformOf = resourcePlatformLookup(accounts);
  return groupByPlatformScope(
    resources.filter((resource) => resource.id),
    platformOf,
    (resource) => resource.name || (resource.id ?? ''),
  );
}

/** Groups accounts under their own registry scope. */
export function groupAccountsByPlatform(
  accounts: readonly Account[],
): readonly PlatformOptionGroup<Account>[] {
  return groupByPlatformScope(
    accounts.filter((account) => account.id),
    (account) => account.platform,
    (account) => account.name || (account.id ?? ''),
  );
}
