import { api } from '$lib/api/client';
import type { Account, Platform, Release, Resource } from '$lib/api/types';
import { PLATFORM_ORDER } from '$lib/format';
import type { Scope } from './types';

/**
 * Accounts, resources and releases: the small, slow-changing half of the data, loaded once per
 * visit and indexed so no screen walks a list to find a name or a platform.
 */
export interface Catalog {
	accounts: Account[];
	resources: Resource[];
	releases: Release[];
	resourceByID: ReadonlyMap<string, Resource>;
	accountByID: ReadonlyMap<string, Account>;
	/** Resource id → the platform of the account that owns it. */
	platformOf: ReadonlyMap<string, Platform>;
	/** Platforms that have at least one account, in display order. */
	platforms: Platform[];
}

let pending: Promise<Catalog> | null = null;

export function loadCatalog(force = false): Promise<Catalog> {
	if (!pending || force) {
		pending = Promise.all([
			api<Account[]>('/accounts'),
			api<Resource[]>('/resources'),
			api<Release[]>('/releases')
		]).then(([accounts, resources, releases]) => index(accounts, resources, releases));
		// A failed load must not be cached, or one network blip breaks the page until a reload.
		pending.catch(() => (pending = null));
	}
	return pending;
}

/** Drops the cached catalog, so the next load refetches — after an admin edits the catalog. */
export function invalidateCatalog(): void {
	pending = null;
}

function index(accounts: Account[], resources: Resource[], releases: Release[]): Catalog {
	// IDs arrive as uppercase UUIDs from Swift's encoder, and route params are whatever was typed
	// into the address bar. Normalising once here means every lookup can use lowercase keys.
	const norm = (id: string | null | undefined) => id?.toLowerCase() ?? '';

	const accountByID = new Map(accounts.filter((a) => a.id).map((a) => [norm(a.id), a]));
	const resourceByID = new Map(resources.filter((r) => r.id).map((r) => [norm(r.id), r]));
	const platformOf = new Map<string, Platform>();
	for (const resource of resources) {
		const platform = accountByID.get(norm(resource.accountID))?.platform;
		if (resource.id && platform) platformOf.set(norm(resource.id), platform);
	}

	const present = new Set(accounts.map((a) => a.platform).filter(Boolean) as Platform[]);

	return {
		accounts,
		resources,
		releases,
		resourceByID,
		accountByID,
		platformOf,
		platforms: PLATFORM_ORDER.filter((p) => present.has(p))
	};
}

/** Lowercased ids of the resources the scope admits. */
export function scopedResourceIDs(
	catalog: Catalog,
	scope: Pick<Scope, 'platform' | 'resourceID'>
): Set<string> {
	if (scope.resourceID) return new Set([scope.resourceID.toLowerCase()]);
	const ids = new Set<string>();
	for (const [id, platform] of catalog.platformOf) {
		if (!scope.platform || platform === scope.platform) ids.add(id);
	}
	return ids;
}
