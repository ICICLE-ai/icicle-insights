import { describe, expect, it } from 'vitest';

import type { Account, Resource } from '../../core/api/models';
import { groupAccountsByPlatform, groupResourcesByPlatform } from './option-groups';

const ACCOUNTS: readonly Account[] = [
  { id: 'npm-1', name: 'icicle-ai', platform: 'npm' },
  { id: 'pypi-1', name: 'icicle-ai', platform: 'pypi' },
  { id: 'gh-1', name: 'icicle-ai', platform: 'github' },
  { id: 'gh-2', name: 'aardvark', platform: 'github' },
];

function resource(id: string, name: string, accountID?: string): Resource {
  return { id, name, accountID, type: 'repository' };
}

describe('groupAccountsByPlatform', () => {
  it('uses the dashboard scope taxonomy, naming what each registry publishes', () => {
    const groups = groupAccountsByPlatform(ACCOUNTS);
    expect(groups.map((group) => group.label)).toStrictEqual([
      'Repositories · GitHub',
      'Packages · npm + PyPI',
    ]);
  });

  it('names the registry on each option inside a multi-registry scope', () => {
    // Collapsing npm and PyPI re-merges two registries the picker still has to tell apart, so
    // the distinction moves onto the option rather than disappearing.
    const packages = groupAccountsByPlatform(ACCOUNTS).find((group) => group.scope === 'packages');
    expect(packages?.options.map((option) => option.label)).toStrictEqual([
      'icicle-ai · npm',
      'icicle-ai · PyPI',
    ]);
  });

  it('leaves options unqualified under a single-registry scope', () => {
    // The heading already names the only registry in play, so a suffix would repeat it.
    const repos = groupAccountsByPlatform(ACCOUNTS).find((group) => group.scope === 'repositories');
    expect(repos?.options.map((option) => option.label)).toStrictEqual(['aardvark', 'icicle-ai']);
  });

  it('keeps scope order stable regardless of catalog contents', () => {
    const packagesOnly = groupAccountsByPlatform([
      { id: 'npm-1', name: 'a', platform: 'npm' },
      { id: 'gh-1', name: 'b', platform: 'github' },
    ]);
    const reversed = groupAccountsByPlatform([
      { id: 'gh-1', name: 'b', platform: 'github' },
      { id: 'npm-1', name: 'a', platform: 'npm' },
    ]);
    expect(packagesOnly.map((group) => group.scope)).toStrictEqual(
      reversed.map((group) => group.scope),
    );
  });

  it('drops scopes with nothing in them', () => {
    const groups = groupAccountsByPlatform([{ id: 'gh-1', name: 'solo', platform: 'github' }]);
    expect(groups).toHaveLength(1);
    expect(groups[0].label).toBe('Repositories · GitHub');
  });

  it('omits an account with no id, which could not be selected anyway', () => {
    const groups = groupAccountsByPlatform([
      { name: 'idless', platform: 'github' },
      { id: 'gh-1', name: 'real', platform: 'github' },
    ]);
    expect(groups[0].options.map((option) => option.item.id)).toStrictEqual(['gh-1']);
  });

  it('is empty for no accounts', () => {
    expect(groupAccountsByPlatform([])).toStrictEqual([]);
  });
});

describe('groupResourcesByPlatform', () => {
  it('resolves a resource registry through its owning account', () => {
    const groups = groupResourcesByPlatform(
      [resource('r1', 'insights', 'gh-1'), resource('r2', 'sdk', 'npm-1')],
      ACCOUNTS,
    );
    expect(groups.map((group) => group.label)).toStrictEqual([
      'Repositories · GitHub',
      'Packages · npm',
    ]);
    expect(groups[0].options[0].item.id).toBe('r1');
  });

  it('describes a scope by the registries actually present, and skips the suffix then', () => {
    // Only npm resources exist here, so the heading must not promise PyPI options that are not
    // in the list — and with one registry in play there is nothing for a suffix to disambiguate.
    const groups = groupResourcesByPlatform([resource('r1', 'sdk', 'npm-1')], ACCOUNTS);
    expect(groups[0].label).toBe('Packages · npm');
    expect(groups[0].options[0].label).toBe('sdk');
  });

  it('qualifies options once both package registries are in the list', () => {
    const groups = groupResourcesByPlatform(
      [resource('r1', 'sdk', 'npm-1'), resource('r2', 'sdk', 'pypi-1')],
      ACCOUNTS,
    );
    expect(groups[0].label).toBe('Packages · npm + PyPI');
    expect(groups[0].options.map((option) => option.label)).toStrictEqual([
      'sdk · npm',
      'sdk · PyPI',
    ]);
  });

  it('keeps an orphaned resource in a trailing catch-all rather than dropping it', () => {
    // Silently omitting it would hide a data problem behind an option that simply is not there.
    const groups = groupResourcesByPlatform(
      [resource('r1', 'insights', 'gh-1'), resource('r2', 'orphan', 'deleted-account')],
      ACCOUNTS,
    );

    const last = groups.at(-1);
    expect(last?.scope).toBeNull();
    expect(last?.label).toBe('Unknown registry');
    expect(last?.options.map((option) => option.item.id)).toStrictEqual(['r2']);
  });

  it('treats a resource with no account at all as ungrouped', () => {
    const groups = groupResourcesByPlatform([resource('r1', 'loose')], ACCOUNTS);
    expect(groups).toHaveLength(1);
    expect(groups[0].scope).toBeNull();
  });

  it('adds no catch-all group when every resource resolves', () => {
    const groups = groupResourcesByPlatform([resource('r1', 'insights', 'gh-1')], ACCOUNTS);
    expect(groups.every((group) => group.scope !== null)).toBe(true);
  });
});
