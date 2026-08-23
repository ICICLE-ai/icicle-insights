import { provideZonelessChangeDetection, signal, type WritableSignal } from '@angular/core';
import { TestBed, type ComponentFixture } from '@angular/core/testing';
import { beforeEach, describe, expect, it } from 'vitest';

import { SessionStore } from '../../core/auth/session-store';
import { TokenStore } from '../../core/auth/token-store';
import { AdminOverview } from './admin-overview';
import { AdminStore, type AdminSnapshot } from './admin-store';

/**
 * Covers the watchlist panel's filtering, paging, and empty states.
 *
 * Rendered rather than unit-tested through the class because the behaviour worth protecting is
 * in the template: which of the three states shows, what the paginator is bound to, and whether
 * an expanded reason row survives a filter change. The admin area is unreachable in a browser
 * without a live Tapis session, so this is where that verification happens.
 */
describe('AdminOverview watchlist', () => {
  let snapshot: WritableSignal<AdminSnapshot>;

  /** A resource overdue for collection becomes one `critical` watchlist row per asset. */
  function overdueResource(name: string, daysOverdue: number) {
    return {
      id: `resource-${name}`,
      name,
      type: 'repository' as const,
      accountID: 'account-1',
      nextCollectionAt: new Date(Date.now() - daysOverdue * 86_400_000).toISOString(),
      collectionIntervalDays: 7,
    };
  }

  function snapshotWith(resources: readonly ReturnType<typeof overdueResource>[]): AdminSnapshot {
    return {
      accounts: [{ id: 'account-1', name: 'icicle-ai', platform: 'github' }],
      resources,
      vaults: [],
      serviceTokens: [],
      admins: [],
      watermarks: [],
      queue: { queue: 'metrics', pending: 0, processing: 0, schedulerState: 'healthy' },
      jobFailures: [],
      loadedAt: new Date(),
    };
  }

  beforeEach(async () => {
    snapshot = signal(snapshotWith([]));

    await TestBed.configureTestingModule({
      imports: [AdminOverview],
      providers: [
        provideZonelessChangeDetection(),
        {
          provide: AdminStore,
          useValue: {
            snapshot,
            isLoading: signal(false),
            error: signal(null),
            reload: () => undefined,
          },
        },
        { provide: SessionStore, useValue: { username: signal('cguz109'), isAdmin: signal(true) } },
        { provide: TokenStore, useValue: { source: signal('cookie'), hasToken: signal(true) } },
      ],
    }).compileComponents();
  });

  async function render(): Promise<{
    fixture: ComponentFixture<AdminOverview>;
    root: HTMLElement;
  }> {
    const fixture = TestBed.createComponent(AdminOverview);
    await fixture.whenStable();
    return { fixture, root: fixture.nativeElement as HTMLElement };
  }

  async function choose(
    fixture: ComponentFixture<AdminOverview>,
    selector: string,
    value: string,
  ): Promise<void> {
    const select = (fixture.nativeElement as HTMLElement).querySelector<HTMLSelectElement>(
      selector,
    );
    if (!select) {
      throw new Error(`no ${selector} in the rendered panel`);
    }
    select.value = value;
    select.dispatchEvent(new Event('change'));
    await fixture.whenStable();
  }

  const rows = (root: HTMLElement): number =>
    root.querySelectorAll('.ins-attention__table tbody tr:not(.ins-attention__reason-row)').length;

  it('shows the all-clear state and no filters when nothing needs attention', async () => {
    const { root } = await render();

    expect(root.querySelector('.ins-attention__clear')).not.toBeNull();
    expect(root.querySelector('.ins-attention__clear.is-filtered')).toBeNull();
    // Nothing to filter, so offering the controls would be furniture.
    expect(root.querySelector('.ins-attention__filters')).toBeNull();
    expect(root.querySelector('app-paginator nav')).toBeNull();
  });

  it('pages the table instead of truncating the list', async () => {
    // Ten rows against a page size of eight: the old panel showed seven and stranded the rest.
    snapshot.set(
      snapshotWith(Array.from({ length: 10 }, (_, i) => overdueResource(`repo-${i}`, 5))),
    );
    const { root } = await render();

    expect(rows(root)).toBe(8);
    const summary = root.querySelector('.ins-admin-pager__summary')?.textContent ?? '';
    expect(summary).toContain('of 10');
  });

  it('filters by priority and reports the filtered total in the paginator', async () => {
    snapshot.set(
      snapshotWith([
        ...Array.from({ length: 9 }, (_, i) => overdueResource(`late-${i}`, 5)),
        // Not yet due: contributes to the summary but not to the critical rows.
        { ...overdueResource('soon', -1) },
      ]),
    );
    const { fixture, root } = await render();

    await choose(fixture, '#attention-priority', 'critical');

    const summary = root.querySelector('.ins-admin-pager__summary')?.textContent ?? '';
    // The count must track the filtered rows, not the unfiltered watchlist.
    expect(summary).toContain('of 9');
    expect(root.querySelectorAll('.ins-priority')).not.toHaveLength(0);
  });

  it('filters by affected asset', async () => {
    snapshot.set(snapshotWith([overdueResource('insights', 5), overdueResource('tapis', 5)]));
    const { fixture, root } = await render();

    const options = [...root.querySelectorAll('#attention-asset option')].map(
      (option) => option.textContent?.trim() ?? '',
    );
    expect(options).toContain('All assets');
    const asset = options.find((option) => option.includes('insights'));
    expect(asset).toBeDefined();

    await choose(fixture, '#attention-asset', asset ?? '');
    expect(rows(root)).toBe(1);
  });

  it('distinguishes "no matches" from "all clear"', async () => {
    snapshot.set(snapshotWith([overdueResource('insights', 5)]));
    const { fixture, root } = await render();

    // Overdue rows are critical, so asking for notices can only match nothing.
    await choose(fixture, '#attention-priority', 'notice');

    const empty = root.querySelector('.ins-attention__clear.is-filtered');
    expect(empty).not.toBeNull();
    // The reassuring copy would be a lie here — items exist, they are just hidden.
    expect(empty?.textContent).toContain('No items match');
    expect(root.querySelector('.ins-attention__table')).toBeNull();
    // The filters stay on screen, or there is no way back to the wider view.
    expect(root.querySelector('.ins-attention__filters')).not.toBeNull();
  });

  it('closes an expanded reason row when a filter changes', async () => {
    snapshot.set(snapshotWith([overdueResource('insights', 5), overdueResource('tapis', 5)]));
    const { fixture, root } = await render();

    root.querySelector<HTMLButtonElement>('.ins-attention__why')?.click();
    await fixture.whenStable();
    expect(root.querySelector('.ins-attention__reason-row')).not.toBeNull();

    await choose(fixture, '#attention-priority', 'critical');
    // Its row may no longer be on this page, and its aria-controls target would go with it.
    expect(root.querySelector('.ins-attention__reason-row')).toBeNull();
  });

  it('keeps the heading count on the unfiltered total', async () => {
    snapshot.set(snapshotWith([overdueResource('insights', 5), overdueResource('tapis', 5)]));
    const { fixture, root } = await render();

    await choose(fixture, '#attention-priority', 'notice');
    // A standing KPI, not a result count: filtering must not make the board look clearer.
    expect(root.querySelector('.ins-panel-heading__count')?.textContent?.trim()).toBe('2');
  });
});
