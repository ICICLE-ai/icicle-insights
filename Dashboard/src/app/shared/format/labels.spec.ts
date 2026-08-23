import { describe, expect, it } from 'vitest';

import {
  PLATFORM_ORDER,
  RESOURCE_TYPE_ORDER,
  SERIES_SLOT_COUNT,
  metricBaseLabel,
  metricLabel,
  metricWindowNote,
  platformColor,
  platformFilterIncludes,
  platformFilterLabel,
  platformLabel,
  platformScopes,
  resourceTypeColor,
  seriesColor,
} from './labels';

describe('metricLabel', () => {
  it('qualifies the window for metrics whose bare name overstates it', () => {
    // These three read as lifetime totals otherwise, which is the whole reason the map exists.
    expect(metricLabel('downloads')).toBe('Downloads · 30 days');
    expect(metricLabel('clones')).toBe('Clones · 14 days');
    expect(metricLabel('views')).toBe('Views · 14 days');
  });

  it('derives all-time labels from the suffix rather than a second lookup table', () => {
    expect(metricLabel('downloadsAllTime')).toBe('Downloads · all time');
    expect(metricLabel('clonesAllTime')).toBe('Clones · all time');
    expect(metricLabel('viewsAllTime')).toBe('Views · all time');
  });

  it('does not let the windowed override leak onto the all-time twin', () => {
    // `downloads` maps to "30 days"; `downloadsAllTime` must not inherit that qualifier.
    expect(metricLabel('downloadsAllTime')).not.toContain('30 days');
  });

  it('title-cases anything without a special case', () => {
    expect(metricLabel('stars')).toBe('Stars');
    expect(metricLabel('forks')).toBe('Forks');
  });

  it('passes through an unrecognised type rather than dropping it', () => {
    expect(metricLabel('somethingNew')).toBe('SomethingNew');
  });
});

describe('metricBaseLabel', () => {
  it('drops the window qualifier the picker does not need', () => {
    expect(metricBaseLabel('downloads')).toBe('Downloads');
    expect(metricBaseLabel('clones')).toBe('Clones');
    expect(metricBaseLabel('views')).toBe('Views');
  });

  it('collapses an all-time twin onto the same bare name as its windowed pair', () => {
    // Both dashboard metric pickers rely on this, and both separate the twins with optgroup
    // headings precisely because the label alone can no longer tell them apart.
    expect(metricBaseLabel('downloadsAllTime')).toBe('Downloads');
    expect(metricBaseLabel('downloadsAllTime')).toBe(metricBaseLabel('downloads'));
    expect(metricBaseLabel('viewsAllTime')).toBe('Views');
  });

  it('agrees with metricLabel wherever the name is already exact', () => {
    for (const type of ['stars', 'forks', 'likes', 'subscribers']) {
      expect(metricBaseLabel(type)).toBe(metricLabel(type));
    }
  });
});

describe('metricWindowNote', () => {
  it('names the window for every metric whose bare label omits one', () => {
    // The pairing that keeps `metricBaseLabel` honest: each type the bare label strips a
    // qualifier from must have a note to carry that information instead.
    for (const type of ['downloads', 'clones', 'views']) {
      expect(metricLabel(type)).not.toBe(metricBaseLabel(type));
      expect(metricWindowNote(type)).toContain('days');
    }
  });

  it('is null for metrics that need no qualification', () => {
    expect(metricWindowNote('stars')).toBeNull();
    expect(metricWindowNote('forks')).toBeNull();
    expect(metricWindowNote('downloadsAllTime')).toBeNull();
  });
});

describe('platformLabel', () => {
  it('uses each project own spelling', () => {
    expect(platformLabel('github')).toBe('GitHub');
    expect(platformLabel('huggingface')).toBe('Hugging Face');
    expect(platformLabel('pypi')).toBe('PyPI');
    expect(platformLabel('npm')).toBe('npm');
  });

  it('falls back to the raw value for a platform this client does not know', () => {
    expect(platformLabel('gitlab')).toBe('gitlab');
  });
});

describe('platform groups', () => {
  it('names every scope by what it publishes, not by the registry brand', () => {
    expect(platformScopes(PLATFORM_ORDER)).toEqual([
      {
        value: 'repositories',
        label: 'Repositories',
        description: 'GitHub',
        platforms: ['github'],
      },
      { value: 'containers', label: 'Containers', description: 'GHCR', platforms: ['ghcr'] },
      {
        value: 'models',
        label: 'Models & Datasets',
        description: 'Hugging Face',
        platforms: ['huggingface'],
      },
      {
        value: 'packages',
        label: 'Packages',
        description: 'npm + PyPI',
        platforms: ['npm', 'pypi'],
      },
    ]);
  });

  it('keeps models and datasets in one scope, because both are one registry', () => {
    // Separating them is a resource-type question, not a registry one — Hugging Face publishes
    // both, so no membership list keyed on platforms can split them.
    const scopes = platformScopes(PLATFORM_ORDER);
    expect(scopes.filter((scope) => scope.platforms.includes('huggingface'))).toHaveLength(1);
  });

  it('uses group membership for filtering and labels', () => {
    expect(platformFilterLabel('packages')).toBe('Packages');
    expect(platformFilterIncludes('packages', 'npm')).toBe(true);
    expect(platformFilterIncludes('packages', 'pypi')).toBe(true);
    expect(platformFilterIncludes('packages', 'github')).toBe(false);
  });

  it('describes a group from the providers that are actually present', () => {
    expect(platformScopes(['github', 'npm'])).toContainEqual({
      value: 'packages',
      label: 'Packages',
      description: 'npm',
      platforms: ['npm'],
    });
  });
});

describe('canonical orderings', () => {
  it('lists resource types matching the server enum, with no image type', () => {
    // The previous dashboard ordered an `image` type the API cannot return.
    expect(RESOURCE_TYPE_ORDER).toEqual([
      'container',
      'dataset',
      'model',
      'package',
      'repository',
      'service',
    ]);
    expect(RESOURCE_TYPE_ORDER).not.toContain('image');
  });

  it('lists every platform the server enum defines', () => {
    expect([...PLATFORM_ORDER].sort()).toEqual(['ghcr', 'github', 'huggingface', 'npm', 'pypi']);
  });

  it('keeps both orderings within the validated palette', () => {
    // Past eight slots the ramp has no further validated hue, so an ordering longer than the
    // palette would silently fall through to the neutral.
    expect(PLATFORM_ORDER.length).toBeLessThanOrEqual(SERIES_SLOT_COUNT);
    expect(RESOURCE_TYPE_ORDER.length).toBeLessThanOrEqual(SERIES_SLOT_COUNT);
  });
});

describe('seriesColor', () => {
  it('maps slots onto the validated ramp', () => {
    expect(seriesColor(0)).toBe('var(--ins-series-1)');
    expect(seriesColor(7)).toBe('var(--ins-series-8)');
  });

  it('does not cycle past the ramp', () => {
    // Cycling would reuse a hue already on screen and break the CVD separation the ramp was
    // validated for; a neutral is the honest answer.
    expect(seriesColor(SERIES_SLOT_COUNT)).toBe('var(--ins-ink-muted)');
    expect(seriesColor(-1)).toBe('var(--ins-ink-muted)');
  });

  it('assigns an entity the same colour regardless of what else is displayed', () => {
    // Colour follows the entity, never its rank — a filter that removes GitHub must not
    // repaint the platforms that survive.
    expect(platformColor('huggingface')).toBe('var(--ins-platform-huggingface)');
    expect(platformColor('pypi')).toBe('var(--ins-platform-pypi)');
    expect(resourceTypeColor('model')).toBe('var(--ins-series-3)');
  });
});
