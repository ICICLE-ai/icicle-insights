import { describe, expect, it } from 'vitest';

import type { Release, Resource } from '../../../core/api/models';
import { buildReleaseCluster, wrapResourceLabel } from './release-graph';

describe('wrapResourceLabel', () => {
  it('keeps a short name on one line', () => {
    expect(wrapResourceLabel('harvest', 118, 12, 3)).toEqual(['harvest']);
  });

  it('breaks a hyphenated name at its hyphens', () => {
    const lines = wrapResourceLabel('food-access-model-service', 90, 12, 3);
    expect(lines.length).toBeGreaterThan(1);
    expect(lines.join('')).toBe('food-access-model-service');
  });

  it('hard-breaks a single unbroken token that is wider than the box, then ellipsizes', () => {
    const lines = wrapResourceLabel(
      'gnnfoodflowportalorganizationsicclassifierforsmartfoodsheds',
      90,
      12,
      3,
    );
    expect(lines.length).toBe(3);
    expect(lines[2].endsWith('…')).toBe(true);
  });

  it('never returns more lines than requested', () => {
    const lines = wrapResourceLabel('one two three four five six seven eight nine', 60, 12, 2);
    expect(lines.length).toBeLessThanOrEqual(2);
  });
});

function makeResource(id: string, name: string): Resource {
  return { id, name, type: 'repository' };
}

function makeRelease(
  id: string,
  resourceID: string,
  releasedAt: string,
  version = '1.0.0',
): Release {
  return { id, resourceID, releasedAt, version };
}

describe('buildReleaseCluster', () => {
  const resources = [
    makeResource('r1', 'alpha'),
    makeResource('r2', 'beta'),
    makeResource('r3', 'gamma'),
  ];

  it('clusters every resource released in the selected period around one hub vertex', () => {
    const releases = [
      makeRelease('a', 'r1', '2026-05-01T00:00:00Z'),
      makeRelease('b', 'r2', '2026-05-15T00:00:00Z'),
      makeRelease('c', 'r3', '2026-06-01T00:00:00Z'),
    ];

    const cluster = buildReleaseCluster(releases, resources, '2026-05');

    const hub = cluster.vertices.filter((vertex) => vertex.kind === 'period');
    const peers = cluster.vertices.filter((vertex) => vertex.kind === 'resource');
    expect(hub).toHaveLength(1);
    expect(hub[0].label).toBe('2026-05');
    expect(peers.map((vertex) => vertex.resourceID).sort()).toEqual(['r1', 'r2']);
    expect(cluster.edges).toHaveLength(2);
    expect(cluster.edges.every((edge) => edge.source === hub[0].id)).toBe(true);
  });

  it('produces a hub-plus-one-peer cluster for a period with a single resource', () => {
    const releases = [makeRelease('a', 'r1', '2026-07-01T00:00:00Z')];

    const cluster = buildReleaseCluster(releases, resources, '2026-07');

    expect(cluster.vertices.filter((vertex) => vertex.kind === 'period')).toHaveLength(1);
    expect(cluster.vertices.filter((vertex) => vertex.kind === 'resource')).toHaveLength(1);
    expect(cluster.edges).toHaveLength(1);
  });

  it('caps the cluster and reports how many resources were omitted when a period is crowded', () => {
    const releases = Array.from({ length: 15 }, (_, index) =>
      makeRelease(
        `r${index}`,
        `resource-${index}`,
        `2026-05-${String(index + 1).padStart(2, '0')}T00:00:00Z`,
      ),
    );
    const manyResources = releases.map((release) =>
      makeResource(release.resourceID as string, release.resourceID as string),
    );

    const cluster = buildReleaseCluster(releases, manyResources, '2026-05');

    const peers = cluster.vertices.filter((vertex) => vertex.kind === 'resource');
    expect(peers.length).toBeLessThanOrEqual(10);
    expect(cluster.omittedCount).toBeGreaterThan(0);
  });

  it('returns an empty cluster for a period with no releases', () => {
    const cluster = buildReleaseCluster([], resources, '2026-05');
    expect(cluster.vertices).toHaveLength(0);
    expect(cluster.edges).toHaveLength(0);
  });

  it('returns an empty cluster when no period is selected', () => {
    const cluster = buildReleaseCluster(
      [makeRelease('a', 'r1', '2026-05-01T00:00:00Z')],
      resources,
      '',
    );
    expect(cluster.vertices).toHaveLength(0);
  });
});
