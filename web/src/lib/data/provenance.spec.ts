import { describe, expect, it } from 'vitest';
import type { Platform, Resource } from '$lib/api/types';
import { buildProvenance } from './provenance';

const platforms = new Map<string, Platform>([
	['p1', 'patra'],
	['h1', 'huggingface'],
	['g1', 'github'],
	['p2', 'patra'],
	['g2', 'github']
]);

const resource = (
	id: string,
	name: string,
	links: { id: string; name: string }[] = []
): Resource => ({
	id,
	name,
	links: links.map((link) => ({ ...link, platform: platforms.get(link.id) }))
});

describe('buildProvenance', () => {
	it('groups linked rows into one cluster led by the most-linked row', () => {
		const { clusters, links } = buildProvenance(
			[
				resource('P1', 'CAN Benchmark', [
					{ id: 'h1', name: 'can_benchmark' },
					{ id: 'g1', name: 'can-benchmark' }
				]),
				resource('h1', 'can_benchmark'),
				resource('g1', 'can-benchmark')
			],
			platforms
		);
		expect(links).toHaveLength(2);
		expect(clusters).toHaveLength(1);
		expect(clusters[0].hub.id).toBe('p1');
		expect(clusters[0].others.map((n) => n.name)).toEqual(['can_benchmark', 'can-benchmark']);
	});

	it('keeps unrelated artifacts in separate clusters, sorted by name', () => {
		const { clusters } = buildProvenance(
			[
				resource('p2', 'MegaDetector', [{ id: 'g2', name: 'camera_trap' }]),
				resource('p1', 'CAN Benchmark', [{ id: 'h1', name: 'can_benchmark' }])
			],
			platforms
		);
		expect(clusters.map((c) => c.hub.name)).toEqual(['CAN Benchmark', 'MegaDetector']);
	});

	it('ignores resources without links and self-links', () => {
		const { clusters } = buildProvenance(
			[resource('g1', 'solo', [{ id: 'G1', name: 'solo' }])],
			platforms
		);
		expect(clusters).toEqual([]);
	});
});
