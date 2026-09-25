import { api } from '$lib/api/client';
import type {
	Account,
	Admin,
	JobFailureInsight,
	Metric,
	MetricType,
	Platform,
	QueueInsight,
	Release,
	Resource,
	ResourceType,
	ServiceToken,
	ServiceTokenMinted,
	Vault,
	WatermarkInsight
} from '$lib/api/types';
import { invalidateCatalog } from '$lib/data/catalog';

/**
 * Every call the admin console makes. Reads are fresh on each screen visit; any write that
 * changes accounts, resources or releases also drops the public pages' cached catalog, so the
 * dashboard reflects an edit without a reload.
 */

export interface ExpirationDate {
	day: number;
	month: number;
	year: number;
}

const writes = async <T>(call: Promise<T>): Promise<T> => {
	const result = await call;
	invalidateCatalog();
	return result;
};

export const adminApi = {
	admins: () => api<Admin[]>('/admins'),
	accounts: () => api<Account[]>('/accounts'),
	resources: () => api<Resource[]>('/resources'),
	releases: () => api<Release[]>('/releases'),
	vaults: () => api<Vault[]>('/vaults'),
	serviceTokens: () => api<ServiceToken[]>('/service-tokens'),
	recentMetrics: (limit = 100) => api<Metric[]>('/metrics', { query: { limit } }),
	queues: () => api<QueueInsight>('/admin/queues'),
	failures: (limit = 50) => api<JobFailureInsight[]>('/admin/failures', { query: { limit } }),
	watermarks: () => api<WatermarkInsight[]>('/admin/watermarks'),

	createAccount: (body: { name: string; platform: Platform }) =>
		writes(api<Account>('/accounts', { method: 'POST', body })),
	deleteAccount: (id: string) => writes(api<void>(`/accounts/${id}`, { method: 'DELETE' })),

	createResource: (body: {
		accountID: string;
		name: string;
		type: ResourceType;
		collectionIntervalDays?: number;
	}) => writes(api<Resource>('/resources', { method: 'POST', body })),
	updateResource: (
		id: string,
		body: { name?: string; type?: ResourceType; collectionIntervalDays?: number }
	) => writes(api<Resource>(`/resources/${id}`, { method: 'PATCH', body })),
	deleteResource: (id: string) => writes(api<void>(`/resources/${id}`, { method: 'DELETE' })),
	// Only queues the job. The resource that comes back has its next collection booked a cadence
	// out, which the public resource page shows, hence `writes`.
	collectResource: (id: string) =>
		writes(api<Resource>(`/resources/${id}/collect`, { method: 'POST' })),

	createRelease: (body: { resourceID: string; version: string; month: number; year: number }) =>
		writes(api<Release>('/releases', { method: 'POST', body })),
	updateRelease: (id: string, body: { version?: string; month?: number; year?: number }) =>
		writes(api<Release>(`/releases/${id}`, { method: 'PATCH', body })),
	deleteRelease: (id: string) => writes(api<void>(`/releases/${id}`, { method: 'DELETE' })),

	createMetric: (body: { resourceID: string; type: MetricType; reading: number }) =>
		api<Metric>('/metrics', { method: 'POST', body }),
	updateMetric: (id: string, body: { reading?: number; type?: MetricType }) =>
		api<Metric>(`/metrics/${id}`, { method: 'PATCH', body }),
	deleteMetric: (id: string) => api<void>(`/metrics/${id}`, { method: 'DELETE' }),

	createVault: (body: { accountID: string; token: string; expires: ExpirationDate }) =>
		api<Vault>('/vaults', { method: 'POST', body }),
	rotateVault: (id: string, body: { token: string; expires: ExpirationDate }) =>
		api<Vault>(`/vaults/${id}`, { method: 'PATCH', body }),
	deleteVault: (id: string) => api<void>(`/vaults/${id}`, { method: 'DELETE' }),

	mintServiceToken: (body: { resourceID: string; label: string; expiresInDays?: number }) =>
		api<ServiceTokenMinted>('/service-tokens', { method: 'POST', body }),
	revokeServiceToken: (id: string) =>
		api<ServiceToken>(`/service-tokens/${id}/revoke`, { method: 'POST' }),
	rotateSigningKey: () =>
		api<{ activeKid: string; message: string }>('/service-tokens/rotate-key', { method: 'POST' }),

	addAdmin: (username: string) => api<Admin>('/admins', { method: 'POST', body: { username } }),
	removeAdmin: (id: string) => api<void>(`/admins/${id}`, { method: 'DELETE' })
};

/** Longest cadence each platform accepts, from `Platform.maxCollectionIntervalDays`. */
export const MAX_CADENCE_DAYS: Record<Platform, number> = {
	github: 7,
	huggingface: 30,
	ghcr: 30,
	npm: 30,
	pypi: 30,
	patra: 30
};

/** The `*AllTime` totals are server-derived; the API refuses them as manual readings. */
export const isRecordable = (type: string): boolean => !type.endsWith('AllTime');
