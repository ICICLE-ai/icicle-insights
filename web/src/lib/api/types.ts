import type { components } from './schema';

/**
 * Names for the API's own schemas. `schema.d.ts` is generated from `/openapi.json` by
 * `deno task api:types` — never edit it by hand, regenerate it after a server change.
 */
type Schemas = components['schemas'];

export type Account = Schemas['AccountPublic'];
export type Resource = Schemas['ResourcePublic'] & { card?: ResourceCard | null };
export type ResourceLink = Schemas['ResourceResourceLink'];
export type Release = Schemas['ReleasePublic'];
export type Metric = Schemas['MetricPublic'];
export type MetricType = Schemas['MetricType'];
export type Vault = Schemas['VaultPublic'];
export type Admin = Schemas['AdminPublic'];
export type ServiceToken = Schemas['ServiceTokenPublic'];
export type ServiceTokenMinted = Schemas['ServiceTokenMinted'];
export type QueueInsight = Schemas['QueueInsight'];
export type JobFailureInsight = Schemas['JobFailureInsight'];
export type WatermarkInsight = Schemas['WatermarkInsight'];

export type Platform = Schemas['Platform'];
export type ResourceType = Schemas['ResourceType'];

/**
 * A resource's Patra model card or datasheet: what it is, who made it, and under what licence.
 *
 * Written by hand because the server adding it (`feat/patra-card-details`) is not yet what
 * `just web-types` generates from. Once it is, this can defer to the generated schema. Every field
 * but `kind` and `uuid` is optional: Patra leaves many of them empty, and servers before that
 * change send no `card` at all.
 */
export interface ResourceCard {
	kind: 'model' | 'datasheet';
	uuid: string;
	version?: string | null;
	updatedAt?: string | null;
	description?: string | null;
	author?: string | null;
	category?: string | null;
	license?: string | null;
	framework?: string | null;
	modelType?: string | null;
	inputType?: string | null;
	/** Test accuracy as a fraction, 0 to 1. */
	accuracy?: number | null;
	keywords?: string[] | null;
	gated?: boolean | null;
	size?: string | null;
	format?: string | null;
	publicationYear?: number | null;
	sourceURL?: string | null;
}
