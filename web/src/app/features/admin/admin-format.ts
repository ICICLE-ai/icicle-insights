import { toApiError, type ApiError } from '../../core/api/api-error';
import type { ExpirationDateInput } from './admin-api';

const dateFormatter = new Intl.DateTimeFormat('en-US', {
  month: 'short',
  day: 'numeric',
  year: 'numeric',
});

/**
 * Month-anchored dates carry no meaningful day or time, so they are read in UTC.
 *
 * A release is stored as the first instant of its month — `2023-04-01T00:00:00Z`. Rendered in
 * local time anywhere behind UTC that is March 31, so *every* release displayed a month early.
 * Grouping in `dashboard.ts` already reads UTC parts for this reason; this keeps the admin table
 * agreeing with it.
 */
const monthFormatter = new Intl.DateTimeFormat('en-US', {
  month: 'long',
  year: 'numeric',
  timeZone: 'UTC',
});

/** Human-readable timestamp that remains explicit about missing or malformed API dates. */
export function formatAdminDate(value: string | undefined): string {
  const time = dateValue(value);
  return time === null ? 'Not set' : dateFormatter.format(time);
}

/**
 * Calendar month for a date whose day is an artifact of storage rather than data.
 *
 * Use for release dates. Everything else `formatAdminDate` renders — `createdAt`, `recordedAt`,
 * `expiresAt` — is a real instant, and those stay in the reader's own zone where the time of day
 * is the point.
 */
export function formatAdminMonth(value: string | undefined): string {
  const time = dateValue(value);
  return time === null ? 'Not set' : monthFormatter.format(time);
}

/** Converts the semantic value of a native date input into the API's calendar DTO. */
export function expirationFromInput(value: string): ExpirationDateInput | null {
  const match = /^(\d{4})-(\d{2})-(\d{2})$/u.exec(value);
  if (!match) {
    return null;
  }

  const year = Number(match[1]);
  const month = Number(match[2]);
  const day = Number(match[3]);
  const time = Date.UTC(year, month - 1, day);
  const date = new Date(time);

  if (
    date.getUTCFullYear() !== year ||
    date.getUTCMonth() + 1 !== month ||
    date.getUTCDate() !== day
  ) {
    return null;
  }

  return { year, month, day };
}

/** Default date input value, computed in UTC so it cannot shift a day around local midnight. */
export function futureDateInput(days: number, now = Date.now()): string {
  return new Date(now + days * 24 * 60 * 60 * 1_000).toISOString().slice(0, 10);
}

/** Error copy for compact mutation forms, retaining the request ID needed for support. */
export function mutationFailure(error: unknown): ApiError {
  return toApiError(error);
}

/**
 * Preview of the server-derived Vault credential name, so the create dialog can show it before
 * saving. Must track `Vault.credentialName` in `Sources/Insights/Models/Vault.swift` exactly —
 * the server is what actually assigns the name, this only avoids surprising the admin with it.
 */
export function vaultCredentialNamePreview(platform: string, accountName: string): string {
  let sanitized = '';
  for (const character of accountName.toLowerCase()) {
    if (/[a-z0-9]/u.test(character)) {
      sanitized += character;
    } else if (!sanitized.endsWith('-')) {
      sanitized += '-';
    }
  }
  sanitized = sanitized.replace(/^-+/u, '').replace(/-+$/u, '');
  return `insights-${platform}-${sanitized}`;
}

function dateValue(value: string | undefined): number | null {
  if (!value) {
    return null;
  }

  const time = Date.parse(value);
  return Number.isFinite(time) ? time : null;
}
