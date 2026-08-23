/** A release identifier classified without assuming the API's free-text value is semantic. */
export interface ParsedReleaseVersion {
  readonly raw: string;
  readonly kind: 'semver' | 'date' | 'label';
  readonly major: number | null;
  readonly minor: number | null;
  readonly patch: number | null;
  readonly prerelease: string | null;
}

const SEMVER =
  /^[vV]?(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)(?:-([0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*))?(?:\+[0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*)?$/u;
const CALENDAR_DATE = /^(\d{4})-(\d{2})-(\d{2})$/u;

/**
 * Parses semantic versions for lineage grouping and safely classifies every other tag.
 *
 * Release.version is deliberately free text, so an unrecognised value is a normal label rather
 * than an error. Date tags are identified separately to keep a value such as `2024-05-01` out of
 * a misleading “major version 2024” group.
 */
export function parseReleaseVersion(value: string | null | undefined): ParsedReleaseVersion {
  const raw = value?.trim() ?? '';
  const semver = SEMVER.exec(raw);
  if (semver) {
    return {
      raw,
      kind: 'semver',
      major: Number(semver[1]),
      minor: Number(semver[2]),
      patch: Number(semver[3]),
      prerelease: semver[4] ?? null,
    };
  }

  return {
    raw,
    kind: isCalendarDate(raw) ? 'date' : 'label',
    major: null,
    minor: null,
    patch: null,
    prerelease: null,
  };
}

function isCalendarDate(value: string): boolean {
  const match = CALENDAR_DATE.exec(value);
  if (!match) {
    return false;
  }

  const year = Number(match[1]);
  const month = Number(match[2]);
  const day = Number(match[3]);
  const date = new Date(Date.UTC(year, month - 1, day));
  return (
    date.getUTCFullYear() === year && date.getUTCMonth() + 1 === month && date.getUTCDate() === day
  );
}
