import { Service, computed, inject, resource } from '@angular/core';

import type {
  Account,
  Admin,
  JobFailureInsight,
  QueueInsight,
  Resource,
  ServiceToken,
  Vault,
  WatermarkInsight,
} from '../../core/api/models';
import { AdminApi } from './admin-api';

export interface AdminSnapshot {
  readonly accounts: readonly Account[];
  readonly resources: readonly Resource[];
  readonly vaults: readonly Vault[];
  readonly serviceTokens: readonly ServiceToken[];
  readonly admins: readonly Admin[];
  readonly watermarks: readonly WatermarkInsight[];
  readonly queue: QueueInsight;
  readonly jobFailures: readonly JobFailureInsight[];
  readonly loadedAt: Date;
}

const EMPTY_QUEUE: QueueInsight = {
  queue: 'metrics',
  pending: 0,
  processing: 0,
  schedulerState: 'notObserved',
};

const EMPTY_SNAPSHOT: AdminSnapshot = {
  accounts: [],
  resources: [],
  vaults: [],
  serviceTokens: [],
  admins: [],
  watermarks: [],
  queue: EMPTY_QUEUE,
  jobFailures: [],
  loadedAt: new Date(0),
};

/** Loads one internally consistent operational snapshot for all admin overview panels. */
@Service()
export class AdminStore {
  private readonly api = inject(AdminApi);

  private readonly snapshotResource = resource({
    loader: async (): Promise<AdminSnapshot> => {
      const [accounts, resources, vaults, serviceTokens, admins, watermarks, queue, jobFailures] =
        await Promise.all([
          this.api.loadAccounts(),
          this.api.loadResources(),
          this.api.loadVaults(),
          this.api.loadServiceTokens(),
          this.api.loadAdmins(),
          this.api.loadWatermarks(),
          this.api.loadQueueInsight(),
          this.api.loadJobFailures(),
        ]);

      return {
        accounts,
        resources,
        vaults,
        serviceTokens,
        admins,
        watermarks,
        queue,
        jobFailures,
        loadedAt: new Date(),
      };
    },
  });

  readonly isLoading = computed(() => this.snapshotResource.isLoading());
  readonly error = computed(() => this.snapshotResource.error());
  readonly snapshot = computed(() => this.snapshotResource.value() ?? EMPTY_SNAPSHOT);

  reload(): void {
    this.snapshotResource.reload();
  }
}
