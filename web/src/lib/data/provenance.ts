import type { Platform, Resource } from '$lib/api/types';

/**
 * Groups resources that are the same real artifact on different registries.
 *
 * Patra imports models and datasets that already exist elsewhere, so one artifact is often several
 * resource rows: the CAN Benchmark is a GitHub repository, a Hugging Face dataset and a Patra
 * datasheet. Each Patra card links its row to the others; the connected components of those links
 * are the artifacts.
 *
 * Deterministic on purpose, as in the Angular version: disjoint groups of two to four rows render
 * as a grid of cards, not a force simulation, so the same catalog always draws the same way.
 */

export interface ProvenanceNode {
	id: string;
	name: string;
	platform: Platform | null;
}

export interface ProvenanceCluster {
	/** The row that recorded the links (the Patra card), which the others were recorded against. */
	hub: ProvenanceNode;
	others: ProvenanceNode[];
}

export interface ProvenanceLink {
	from: ProvenanceNode;
	to: ProvenanceNode;
}

export function buildProvenance(
	resources: readonly Resource[],
	platformOf: ReadonlyMap<string, Platform>
): { clusters: ProvenanceCluster[]; links: ProvenanceLink[] } {
	const nodes = new Map<string, ProvenanceNode>();
	const node = (
		id: string,
		name: string | null | undefined,
		platform: Platform | null
	): ProvenanceNode => {
		const key = id.toLowerCase();
		if (!nodes.has(key)) nodes.set(key, { id: key, name: name ?? 'Unnamed', platform });
		return nodes.get(key)!;
	};

	const links: ProvenanceLink[] = [];
	for (const resource of resources) {
		if (!resource.id) continue;
		const id = resource.id.toLowerCase();
		// Only real links make a node: a row whose every link points back at itself is one
		// artifact on one registry, which is not provenance.
		const targets = (resource.links ?? []).filter(
			(link) => link.id && link.id.toLowerCase() !== id
		);
		if (targets.length === 0) continue;
		const from = node(id, resource.name, platformOf.get(id) ?? null);
		for (const link of targets) {
			links.push({
				from,
				to: node(
					link.id!,
					link.name,
					link.platform ?? platformOf.get(link.id!.toLowerCase()) ?? null
				)
			});
		}
	}

	// Union–find over the links.
	const parent = new Map([...nodes.keys()].map((id) => [id, id]));
	const find = (id: string): string => {
		while (parent.get(id) !== id) {
			parent.set(id, parent.get(parent.get(id)!)!);
			id = parent.get(id)!;
		}
		return id;
	};
	for (const { from, to } of links) parent.set(find(to.id), find(from.id));

	// The recording side leads: in a two-row group both rows have one link, and the alphabet would
	// otherwise pick whichever name sorts first rather than the card that says they are the same.
	const recorded = new Map<string, number>();
	const degree = new Map<string, number>();
	for (const { from, to } of links) {
		recorded.set(from.id, (recorded.get(from.id) ?? 0) + 1);
		degree.set(from.id, (degree.get(from.id) ?? 0) + 1);
		degree.set(to.id, (degree.get(to.id) ?? 0) + 1);
	}

	const groups = new Map<string, ProvenanceNode[]>();
	for (const n of nodes.values()) {
		const root = find(n.id);
		groups.set(root, [...(groups.get(root) ?? []), n]);
	}

	const byName = (a: ProvenanceNode, b: ProvenanceNode) =>
		a.name.localeCompare(b.name) || a.id.localeCompare(b.id);
	const clusters = [...groups.values()]
		.map((members) => {
			const [hub, ...others] = [...members].sort(
				(a, b) =>
					(recorded.get(b.id) ?? 0) - (recorded.get(a.id) ?? 0) ||
					(degree.get(b.id) ?? 0) - (degree.get(a.id) ?? 0) ||
					byName(a, b)
			);
			return { hub, others: others.sort(byName) };
		})
		.sort((a, b) => byName(a.hub, b.hub));

	return { clusters, links };
}
