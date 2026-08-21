import { toApiError, type ApiError } from '../../core/api/api-error';
import type { ExpirationDateInput } from './admin-api';

const dateFormatter = new Intl.DateTimeFormat('en-US', {
  month: 'short',
  day: 'numeric',
  year: 'numeric',
});

/** Human-readable timestamp that remains explicit about missing or malformed API dates. */
export function formatAdminDate(value: string | undefined): string {
  const time = dateValue(value);
  return time === null ? 'Not set' : dateFormatter.format(time);
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

function dateValue(value: string | undefined): number | null {
  if (!value) {
    return null;
  }

  const time = Date.parse(value);
  return Number.isFinite(time) ? time : null;
}
