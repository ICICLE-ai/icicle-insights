/**
 * Wire shapes returned by the Insights API.
 *
 * These mirror the `Public` structs in `Sources/Insights/DTOs/*.swift` field for field. Every
 * property is optional on the Swift side — `toPublic()` projects `$field.value`, which is nil for
 * anything the query did not load — so they are optional here too. Tightening them would be
 * lying about a response that legitimately omits relationships.
 *
 * Timestamps arrive as ISO 8601 UTC strings and stay strings until something needs a Date.
 */

/** Providers Insights collects from. Mirrors `Platform` in `Models/Account.swift`. */
export type Platform = 'github' | 'ghcr' | 'huggingface' | 'npm' | 'pypi' | 'patra';

/**
 * Catalog classification of a resource. Mirrors `ResourceType` in `Models/Resource.swift`.
 *
 * Note there is no `image` member. The previous dashboard listed one in its display ordering,
 * which silently sorted a type the API can never return.
 */
export type ResourceType =
  | 'agent'
  | 'container'
  | 'dataset'
  | 'model'
  | 'package'
  | 'repository'
  | 'service';

/**
 * Semantic kind of a reading. Mirrors `MetricType` in `Models/Metric.swift`.
 *
 * The `*AllTime` members are running totals the collector folds up from rolling windows; the
 * bare members are whatever the platform reported for its own window, which differs per platform
 * and is why `metricLabel` exists. `deployments` has no `AllTime` twin: Patra's count is read
 * whole on every sweep, so there is no rolling window to fold.
 */
export type MetricType =
  | 'authentications'
  | 'clones'
  | 'deployments'
  | 'downloads'
  | 'forks'
  | 'likes'
  | 'pulls'
  | 'stars'
  | 'subscribers'
  | 'views'
  | 'authenticationsAllTime'
  | 'clonesAllTime'
  | 'downloadsAllTime'
  | 'pullsAllTime'
  | 'viewsAllTime';

/** A platform account or organization. */
export interface Account {
  id?: string;
  name?: string;
  platform?: Platform;
  followers?: number;
  resources?: Resource[];
  vault?: Vault;
  createdAt?: string;
  updatedAt?: string;
  deletedAt?: string;
}

/** A collectable artifact owned by an account. */
export interface Resource {
  id?: string;
  accountID?: string;
  name?: string;
  type?: ResourceType;
  metrics?: Metric[];
  releases?: Release[];
  /**
   * Other registries this artifact is also known under, deduplicated across this resource's
   * loaded Patra cards. `undefined` means not requested by this endpoint; an empty array means
   * requested and none found — the same "loaded vs. not" contract every other relationship here
   * keeps. Both `GET /resources` and `GET /resources/:id` load this.
   */
  links?: ResourceLink[];
  /** Earliest instant the due-resource sweep may dispatch it. Past-dated means overdue. */
  nextCollectionAt?: string;
  collectionIntervalDays?: number;
  createdAt?: string;
  updatedAt?: string;
  deletedAt?: string;
}

/**
 * One registry where a resource's artifact is also known to exist, per a Patra card.
 *
 * Flattened server-side from the Patra card that recorded the relationship — this carries just
 * enough to draw a graph node and an edge, not the card itself.
 */
export interface ResourceLink {
  id?: string;
  name?: string;
  platform?: Platform;
}

/** One observation of one metric for one resource. */
export interface Metric {
  id?: string;
  resourceID?: string;
  reading?: number;
  type?: MetricType;
  recordedAt?: string;
}

/**
 * Acknowledgement that a manual collection was enqueued.
 *
 * `dispatchedAt` is the whole point of the response: the job runs on the worker long after this
 * returns, so it is what separates a metric or failure caused by this dispatch from one already
 * sitting in the table.
 */
export interface CollectionDispatch {
  resourceID: string;
  dispatchedAt: string;
}

/** A published version of a resource. `version` is free text, not guaranteed semver. */
export interface Release {
  id?: string;
  resourceID?: string;
  version?: string;
  releasedAt?: string;
}

/** Tapis Vault metadata. Never carries the secret value — see `VaultDTO.swift`. */
export interface Vault {
  id?: string;
  accountID?: string;
  name?: string;
  expiresAt?: string;
  createdAt?: string;
  updatedAt?: string;
}

/** Webhook token metadata. Never carries the credential. */
export interface ServiceToken {
  id?: string;
  jti?: string;
  resourceID?: string;
  label?: string;
  expiresAt?: string;
  /** Set once withdrawn. A revoked token keeps its row as the audit trail. */
  revokedAt?: string;
  createdAt?: string;
}

/**
 * The response to a successful mint — the only place a token value is ever returned.
 *
 * Nothing persists it and no route can read it back, so the UI showing this must make clear it
 * will not be shown again.
 */
export interface MintedServiceToken {
  token: string;
  endpoint: string;
  serviceToken: ServiceToken;
}

/** An administrator. `isRoot` marks the environment-configured admin, which cannot be removed. */
export interface Admin {
  id?: string;
  username?: string;
  addedBy?: string;
  createdAt?: string;
  isRoot?: boolean;
}

/** Progress bookmark for folding rolling platform traffic into an all-time total. */
export interface WatermarkInsight {
  id?: string;
  resourceID: string;
  resourceName: string;
  type: MetricType;
  countedThrough: string;
  updatedAt?: string;
}

/** Redis queue depth and the most recently observed scheduled-job heartbeat. */
export interface QueueInsight {
  queue: string;
  pending: number;
  processing: number;
  schedulerLastSeenAt?: string;
  schedulerState: 'healthy' | 'stale' | 'notObserved' | 'unavailable';
}

/** Durable record of a collection job that exhausted its retry budget. */
export interface JobFailureInsight {
  id?: string;
  resourceID?: string;
  accountID?: string;
  job: string;
  subject: string;
  identifier: string;
  details: string;
  severity: 'critical' | 'warning';
  failedAt: string;
}
