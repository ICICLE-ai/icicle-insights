import { provideZonelessChangeDetection } from '@angular/core';
import { TestBed } from '@angular/core/testing';
import { describe, expect, it } from 'vitest';

import type { Platform, Resource, ResourceLink } from '../../../core/api/models';
import {
  ProvenanceGraph,
  buildProvenanceGraph,
  provenancePlatformColorScale,
} from './provenance-graph';

function makeResource(id: string, name: string, links: readonly ResourceLink[] = []): Resource {
  return { id, name, type: 'dataset', links: [...links] };
}

function platformMap(entries: readonly (readonly [string, Platform])[]): ReadonlyMap<string, Platform> {
  return new Map(entries);
}

describe('buildProvenanceGraph', () => {
  it('turns the CAN Benchmark example into a three-node cluster joined by two edges', () => {
    // The scenario the whole graph exists for: one artifact, imported into Patra, that already
    // exists as a GitHub repository and a Hugging Face dataset. Three `Resource` rows, one thing.
    const datasheet = makeResource('patra-1', 'Continually Adapt or Not (CAN) Benchmark', [
      { id: 'gh-1', name: 'can-benchmark', platform: 'github' },
      { id: 'hf-1', name: 'can_benchmark', platform: 'huggingface' },
    ]);

    const graph = buildProvenanceGraph([datasheet], platformMap([['patra-1', 'patra']]));

    expect(graph.vertices).toHaveLength(3);
    expect(graph.vertices.map((v) => v.id).sort()).toEqual(['gh-1', 'hf-1', 'patra-1']);
    expect(graph.edges).toHaveLength(2);
    expect(graph.edges.every((edge) => edge.source === 'patra-1')).toBe(true);
    expect(graph.edges.map((edge) => edge.target).sort()).toEqual(['gh-1', 'hf-1']);
  });

  it('returns an empty graph for a resource with no links — the state every resource is in today', () => {
    const resource = makeResource('r1', 'lonely-resource', []);

    const graph = buildProvenanceGraph([resource], platformMap([['r1', 'github']]));

    expect(graph.vertices).toHaveLength(0);
    expect(graph.edges).toHaveLength(0);
  });

  it('drops a link with no recorded platform rather than drawing an unidentifiable node', () => {
    const resource = makeResource('r1', 'name', [
      { id: 'x', name: 'x', platform: undefined },
    ]);

    const graph = buildProvenanceGraph([resource], platformMap([['r1', 'github']]));

    expect(graph.vertices).toHaveLength(0);
    expect(graph.edges).toHaveLength(0);
  });

  it('skips a resource whose own platform is not in the lookup, rather than drawing a colourless node', () => {
    const resource = makeResource('r1', 'name', [{ id: 'x', name: 'x', platform: 'github' }]);

    const graph = buildProvenanceGraph([resource], platformMap([]));

    expect(graph.vertices).toHaveLength(0);
    expect(graph.edges).toHaveLength(0);
  });

  it('folds a link recorded from both sides into one edge, not two stacked on each other', () => {
    const alpha = makeResource('a', 'alpha', [{ id: 'b', name: 'beta', platform: 'github' }]);
    const beta = makeResource('b', 'beta', [{ id: 'a', name: 'alpha', platform: 'huggingface' }]);

    const graph = buildProvenanceGraph(
      [alpha, beta],
      platformMap([
        ['a', 'huggingface'],
        ['b', 'github'],
      ]),
    );

    expect(graph.vertices).toHaveLength(2);
    expect(graph.edges).toHaveLength(1);
  });

  it('never draws a self-loop for a link that names its own resource', () => {
    const resource = makeResource('r1', 'name', [{ id: 'r1', name: 'name', platform: 'github' }]);

    const graph = buildProvenanceGraph([resource], platformMap([['r1', 'github']]));

    expect(graph.edges).toHaveLength(0);
  });
});

describe('provenance graph vertex labels', () => {
  it('are exactly two lines: the name, then the platform in parentheses', () => {
    const resource = makeResource('patra-1', 'name', [
      { id: 'hf-1', name: 'MegaDetector', platform: 'huggingface' },
    ]);

    const graph = buildProvenanceGraph([resource], platformMap([['patra-1', 'patra']]));

    const vertex = graph.vertices.find((v) => v.id === 'hf-1');
    expect(vertex?.lines).toEqual(['MegaDetector', '(Hugging Face)']);
  });

  it('spells the second line with each project’s own registry name', () => {
    const resource = makeResource('gh-1', 'insights', [
      { id: 'patra-1', name: 'insights-card', platform: 'patra' },
    ]);

    const graph = buildProvenanceGraph([resource], platformMap([['gh-1', 'github']]));

    const source = graph.vertices.find((v) => v.id === 'gh-1');
    const target = graph.vertices.find((v) => v.id === 'patra-1');
    expect(source?.lines[1]).toBe('(GitHub)');
    expect(target?.lines[1]).toBe('(Patra)');
  });
});

describe('provenancePlatformColorScale', () => {
  const fakePalette = {
    platforms: {
      github: '#111111',
      ghcr: '#222222',
      huggingface: '#333333',
      npm: '#444444',
      pypi: '#555555',
      patra: '#666666',
    } as Record<Platform, string>,
  };

  it('takes every colour from the platform palette rather than a chart-rank slot', () => {
    const resource = makeResource('patra-1', 'name', [
      { id: 'gh-1', name: 'x', platform: 'github' },
      { id: 'hf-1', name: 'y', platform: 'huggingface' },
    ]);
    const graph = buildProvenanceGraph([resource], platformMap([['patra-1', 'patra']]));

    const scale = provenancePlatformColorScale(graph.vertices, fakePalette);

    for (const platform of scale.domain) {
      expect(scale.range[scale.domain.indexOf(platform)]).toBe(fakePalette.platforms[platform]);
    }
  });

  it('gives two different platforms two different colours', () => {
    const resource = makeResource('patra-1', 'name', [
      { id: 'gh-1', name: 'x', platform: 'github' },
      { id: 'hf-1', name: 'y', platform: 'huggingface' },
    ]);
    const graph = buildProvenanceGraph([resource], platformMap([['patra-1', 'patra']]));

    const scale = provenancePlatformColorScale(graph.vertices, fakePalette);

    expect(scale.domain).toEqual(['github', 'huggingface', 'patra']);
    expect(new Set(scale.range).size).toBe(scale.range.length);
  });
});

describe('ProvenanceGraph component', () => {
  async function render(
    resources: readonly Resource[],
    resourcePlatform: ReadonlyMap<string, Platform>,
  ): Promise<HTMLElement> {
    await TestBed.configureTestingModule({
      imports: [ProvenanceGraph],
      providers: [provideZonelessChangeDetection()],
    }).compileComponents();

    const fixture = TestBed.createComponent(ProvenanceGraph);
    fixture.componentRef.setInput('resources', resources);
    fixture.componentRef.setInput('resourcePlatform', resourcePlatform);
    await fixture.whenStable();
    return fixture.nativeElement as HTMLElement;
  }

  it('renders the empty state, not a broken or empty chart, for a resource with no links', async () => {
    const root = await render([makeResource('r1', 'lonely', [])], platformMap([['r1', 'github']]));

    expect(root.querySelector('tanstack-chart')).toBeNull();
    expect(root.querySelector('.ins-provenance-graph__empty')).not.toBeNull();
    expect(root.textContent).toContain('No cross-registry links recorded yet');
  });

  it('renders no empty-state notice once at least one link exists', async () => {
    const resource = makeResource('patra-1', 'name', [
      { id: 'gh-1', name: 'x', platform: 'github' },
    ]);

    const root = await render([resource], platformMap([['patra-1', 'patra']]));

    expect(root.querySelector('.ins-provenance-graph__empty')).toBeNull();
  });
});
