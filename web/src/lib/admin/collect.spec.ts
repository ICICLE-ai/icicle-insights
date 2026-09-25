import { describe, expect, it } from 'vitest';
import type { Platform } from '$lib/api/types';
import { collectBlockedReason, HAS_COLLECTOR } from './collect';

describe('collectBlockedReason', () => {
	it.each<Platform>(['github', 'huggingface', 'ghcr', 'patra'])('allows %s', (platform) => {
		expect(collectBlockedReason({ platform })).toBeNull();
	});

	// The API answers 409 for these. Blocking in the menu says why before the click.
	it.each<[Platform, string]>([
		['npm', 'npm is not collected'],
		['pypi', 'PyPI is not collected']
	])('blocks %s', (platform, reason) => {
		expect(collectBlockedReason({ platform })).toBe(reason);
	});

	// `GET /accounts` leaves out soft-deleted accounts, so a missing owner means a deleted one.
	it('blocks a resource whose account is missing from the list', () => {
		expect(collectBlockedReason(undefined)).toBe('Its account has been deleted');
	});

	it('agrees with HAS_COLLECTOR for every platform', () => {
		for (const [platform, collected] of Object.entries(HAS_COLLECTOR) as [Platform, boolean][]) {
			expect(collectBlockedReason({ platform }) === null).toBe(collected);
		}
	});
});
