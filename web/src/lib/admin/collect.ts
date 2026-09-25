import type { Account, Platform } from '$lib/api/types';
import { platformLabel } from '$lib/format';

/**
 * Whether each platform is collected at all, from `Platform.hasCollector` on the server.
 *
 * npm and PyPI are false on purpose: their download counts cannot separate people from CI runners
 * and caches. A `Record` over every platform, so a platform added to the API fails the type check
 * here until someone decides which side it is on.
 */
export const HAS_COLLECTOR: Record<Platform, boolean> = {
	github: true,
	huggingface: true,
	ghcr: true,
	npm: false,
	pypi: false,
	patra: true
};

/**
 * Why **Collect now** cannot run for a resource owned by `owner`, or null when it can.
 *
 * The same two refusals the API answers 409 for, said in the row menu before the request rather
 * than in a toast after it. `owner` comes from `GET /accounts`, which leaves out soft-deleted
 * accounts, so a resource whose account is missing there belongs to a deleted one.
 */
export function collectBlockedReason(owner: Pick<Account, 'platform'> | undefined): string | null {
	if (!owner) return 'Its account has been deleted';
	if (!owner.platform || !HAS_COLLECTOR[owner.platform])
		return `${platformLabel(owner.platform)} is not collected`;
	return null;
}
