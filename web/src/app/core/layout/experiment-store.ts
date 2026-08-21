import { Service, signal } from '@angular/core';

export type AdminOverviewVariant = 'status-first' | 'triage-first';

/** Memory-only design comparisons that exist exclusively behind the development Test Lab. */
@Service()
export class ExperimentStore {
  private readonly adminOverviewState = signal<AdminOverviewVariant>('status-first');

  readonly adminOverview = this.adminOverviewState.asReadonly();

  setAdminOverview(variant: AdminOverviewVariant): void {
    this.adminOverviewState.set(variant);
  }
}
