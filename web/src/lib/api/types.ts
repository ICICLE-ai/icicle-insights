import type { components } from './schema';

/**
 * Names for the API's own schemas. `schema.d.ts` is generated from `/openapi.json` by
 * `deno task api:types` — never edit it by hand, regenerate it after a server change.
 */
type Schemas = components['schemas'];

export type Account = Schemas['AccountPublic'];
export type Resource = Schemas['ResourcePublic'];
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
