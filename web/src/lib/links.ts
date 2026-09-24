import type { Platform, ResourceType } from '$lib/api/types';

/**
 * The resource's own page on its platform, or null where the platform has no stable public URL
 * for it. Built from the same account and name the collectors use to call each platform's API,
 * so a link that 404s means the collector would fail too.
 */
export function platformURL(
	platform: Platform | null,
	account: string | null,
	name: string,
	kind: ResourceType
): string | null {
	if (!platform) return null;
	const encoded = encodeURIComponent(name);
	switch (platform) {
		case 'github':
			return account ? `https://github.com/${account}/${encoded}` : null;
		case 'huggingface':
			return account
				? `https://huggingface.co/${kind === 'dataset' ? 'datasets/' : ''}${account}/${encoded}`
				: null;
		case 'ghcr':
			return account
				? `https://github.com/orgs/${account}/packages/container/package/${encoded}`
				: null;
		case 'npm':
			return `https://www.npmjs.com/package/${encoded}`;
		case 'pypi':
			return `https://pypi.org/project/${encoded}/`;
		case 'patra':
			return null;
	}
}
