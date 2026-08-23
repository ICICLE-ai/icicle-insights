import { describe, expect, it } from 'vitest';

import { parseReleaseVersion } from './release-version';

describe('parseReleaseVersion', () => {
  it('parses v-prefixed semantic versions and prereleases', () => {
    expect(parseReleaseVersion('v2.14.3-rc.1+build.7')).toEqual({
      raw: 'v2.14.3-rc.1+build.7',
      kind: 'semver',
      major: 2,
      minor: 14,
      patch: 3,
      prerelease: 'rc.1',
    });
  });

  it('keeps calendar tags out of semantic major-version groups', () => {
    expect(parseReleaseVersion('2024-05-01')).toMatchObject({
      kind: 'date',
      major: null,
    });
  });

  it('accepts arbitrary provider labels without throwing', () => {
    expect(parseReleaseVersion(' latest ')).toEqual({
      raw: 'latest',
      kind: 'label',
      major: null,
      minor: null,
      patch: null,
      prerelease: null,
    });
    expect(parseReleaseVersion(undefined).kind).toBe('label');
  });

  it('does not classify impossible dates as calendar releases', () => {
    expect(parseReleaseVersion('2026-02-30').kind).toBe('label');
  });
});
