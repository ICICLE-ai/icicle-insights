import { HttpClient, HttpParams } from '@angular/common/http';
import { Service, inject } from '@angular/core';
import { firstValueFrom } from 'rxjs';

import type {
  Account,
  Admin,
  CollectionDispatch,
  MintedServiceToken,
  Resource,
  ServiceToken,
  Vault,
  Metric,
  MetricType,
  WatermarkInsight,
  QueueInsight,
  JobFailureInsight,
  Platform,
  Release,
  ResourceType,
} from '../../core/api/models';
import { INSIGHTS_CONFIG } from '../../core/config';

/** Typed client for the admin-only operational and management API. */
@Service()
export class AdminApi {
  private readonly http = inject(HttpClient);
  private readonly config = inject(INSIGHTS_CONFIG);

  private url(path: string): string {
    return `${this.config.apiBase}${path}`;
  }

  loadAccounts(): Promise<Account[]> {
    return firstValueFrom(this.http.get<Account[]>(this.url('/accounts')));
  }

  loadResources(): Promise<Resource[]> {
    return firstValueFrom(this.http.get<Resource[]>(this.url('/resources')));
  }

  loadVaults(): Promise<Vault[]> {
    return firstValueFrom(this.http.get<Vault[]>(this.url('/vaults')));
  }

  loadServiceTokens(): Promise<ServiceToken[]> {
    return firstValueFrom(this.http.get<ServiceToken[]>(this.url('/service-tokens')));
  }

  loadAdmins(): Promise<Admin[]> {
    return firstValueFrom(this.http.get<Admin[]>(this.url('/admins')));
  }

  loadReleases(): Promise<Release[]> {
    return firstValueFrom(this.http.get<Release[]>(this.url('/releases')));
  }

  loadRecentMetrics(limit = 100): Promise<Metric[]> {
    const params = new HttpParams().set('limit', Math.min(1000, Math.max(1, limit)));
    return firstValueFrom(this.http.get<Metric[]>(this.url('/metrics'), { params }));
  }

  loadWatermarks(): Promise<WatermarkInsight[]> {
    return firstValueFrom(this.http.get<WatermarkInsight[]>(this.url('/admin/watermarks')));
  }

  loadQueueInsight(): Promise<QueueInsight> {
    return firstValueFrom(this.http.get<QueueInsight>(this.url('/admin/queues')));
  }

  loadJobFailures(limit = 50): Promise<JobFailureInsight[]> {
    const params = new HttpParams().set('limit', Math.min(200, Math.max(1, limit)));
    return firstValueFrom(
      this.http.get<JobFailureInsight[]>(this.url('/admin/failures'), { params }),
    );
  }

  createAccount(input: CreateAccountInput): Promise<Account> {
    return firstValueFrom(this.http.post<Account>(this.url('/accounts'), input));
  }

  deleteAccount(id: string): Promise<void> {
    return firstValueFrom(this.http.delete<void>(this.url(`/accounts/${id}`)));
  }

  createResource(input: CreateResourceInput): Promise<Resource> {
    return firstValueFrom(this.http.post<Resource>(this.url('/resources'), input));
  }

  updateResource(id: string, input: UpdateResourceInput): Promise<Resource> {
    return firstValueFrom(this.http.patch<Resource>(this.url(`/resources/${id}`), input));
  }

  deleteResource(id: string): Promise<void> {
    return firstValueFrom(this.http.delete<void>(this.url(`/resources/${id}`)));
  }

  /**
   * Enqueues a collection for one resource, outside its schedule.
   *
   * Resolves when the job is queued, not when it has run. Read the outcome by polling
   * `loadRecentMetrics` and `loadJobFailures` against the returned `dispatchedAt`.
   */
  collectResource(id: string): Promise<CollectionDispatch> {
    return firstValueFrom(
      this.http.post<CollectionDispatch>(this.url(`/resources/${id}/collect`), null),
    );
  }

  createRelease(input: CreateReleaseInput): Promise<Release> {
    return firstValueFrom(this.http.post<Release>(this.url('/releases'), input));
  }

  updateRelease(id: string, input: UpdateReleaseInput): Promise<Release> {
    return firstValueFrom(this.http.patch<Release>(this.url(`/releases/${id}`), input));
  }

  deleteRelease(id: string): Promise<void> {
    return firstValueFrom(this.http.delete<void>(this.url(`/releases/${id}`)));
  }

  createMetric(input: CreateMetricInput): Promise<Metric> {
    return firstValueFrom(this.http.post<Metric>(this.url('/metrics'), input));
  }

  updateMetric(id: string, input: UpdateMetricInput): Promise<Metric> {
    return firstValueFrom(this.http.patch<Metric>(this.url(`/metrics/${id}`), input));
  }

  deleteMetric(id: string): Promise<void> {
    return firstValueFrom(this.http.delete<void>(this.url(`/metrics/${id}`)));
  }

  createVault(input: CreateVaultInput): Promise<Vault> {
    return firstValueFrom(this.http.post<Vault>(this.url('/vaults'), input));
  }

  rotateVault(id: string, input: RotateVaultInput): Promise<Vault> {
    return firstValueFrom(this.http.patch<Vault>(this.url(`/vaults/${id}`), input));
  }

  deleteVault(id: string): Promise<void> {
    return firstValueFrom(this.http.delete<void>(this.url(`/vaults/${id}`)));
  }

  mintServiceToken(input: MintServiceTokenInput): Promise<MintedServiceToken> {
    return firstValueFrom(this.http.post<MintedServiceToken>(this.url('/service-tokens'), input));
  }

  revokeServiceToken(id: string): Promise<ServiceToken> {
    return firstValueFrom(
      this.http.post<ServiceToken>(this.url(`/service-tokens/${id}/revoke`), null),
    );
  }

  rotateServiceTokenKey(): Promise<RotatedSigningKey> {
    return firstValueFrom(
      this.http.post<RotatedSigningKey>(this.url('/service-tokens/rotate-key'), null),
    );
  }

  createAdmin(username: string): Promise<Admin> {
    return firstValueFrom(this.http.post<Admin>(this.url('/admins'), { username }));
  }

  deleteAdmin(id: string): Promise<void> {
    return firstValueFrom(this.http.delete<void>(this.url(`/admins/${id}`)));
  }
}

export interface ExpirationDateInput {
  readonly day: number;
  readonly month: number;
  readonly year: number;
}

export interface CreateVaultInput {
  readonly token: string;
  readonly accountID: string;
  readonly expires: ExpirationDateInput;
}

export interface RotateVaultInput {
  readonly token: string;
  readonly expires: ExpirationDateInput;
}

export interface MintServiceTokenInput {
  readonly resourceID: string;
  readonly label: string;
  readonly expiresInDays?: number;
}

export interface RotatedSigningKey {
  readonly activeKid: string;
  readonly message: string;
}

export interface CreateAccountInput {
  readonly name: string;
  readonly platform: Platform;
}

export interface CreateResourceInput {
  readonly name: string;
  readonly type: ResourceType;
  readonly accountID: string;
  readonly collectionIntervalDays: number;
}

export interface UpdateResourceInput {
  readonly name?: string;
  readonly type?: ResourceType;
  readonly collectionIntervalDays?: number;
}

export interface CreateReleaseInput {
  readonly version: string;
  readonly month: number;
  readonly year: number;
  readonly resourceID: string;
}

export interface UpdateReleaseInput {
  readonly version?: string;
  readonly month?: number;
  readonly year?: number;
}

export interface CreateMetricInput {
  readonly reading: number;
  readonly type: MetricType;
  readonly resourceID: string;
}

export interface UpdateMetricInput {
  readonly reading?: number;
  readonly type?: MetricType;
}
