import { auth } from '$lib/auth.svelte';

/** Same-origin in production (Vapor serves both) and in development (Vite proxies `/api`). */
const API_BASE = '/api';

/**
 * A failed API call, carrying what the server said and the request ID to quote.
 *
 * The server's `AbortError` responses are `{ error: true, reason }`, and every response echoes
 * `X-Request-ID`, which is the one thing an operator needs to find the matching log line.
 */
export class ApiError extends Error {
	constructor(
		readonly status: number,
		readonly reason: string,
		readonly requestID: string | null
	) {
		super(reason);
		this.name = 'ApiError';
	}

	get isAuthFailure(): boolean {
		return this.status === 401 || this.status === 403;
	}
}

type Query = Record<string, string | number | boolean | null | undefined>;

interface RequestOptions {
	method?: 'GET' | 'POST' | 'PATCH' | 'DELETE';
	query?: Query;
	body?: unknown;
	signal?: AbortSignal;
}

/** Calls the Insights API, attaching the administrator's token when one is held. */
export async function api<T>(path: string, options: RequestOptions = {}): Promise<T> {
	const url = new URL(`${API_BASE}${path}`, window.location.origin);
	for (const [key, value] of Object.entries(options.query ?? {})) {
		if (value !== null && value !== undefined && value !== '')
			url.searchParams.set(key, String(value));
	}

	const headers: Record<string, string> = {
		Accept: 'application/json',
		'X-Request-ID': crypto.randomUUID()
	};
	if (auth.token) headers.Authorization = `Bearer ${auth.token}`;
	if (options.body !== undefined) headers['Content-Type'] = 'application/json';

	const response = await fetch(url, {
		method: options.method ?? 'GET',
		headers,
		body: options.body === undefined ? undefined : JSON.stringify(options.body),
		signal: options.signal
	});

	if (!response.ok) {
		let reason = response.statusText || `Request failed with status ${response.status}`;
		try {
			const body = await response.json();
			if (typeof body?.reason === 'string') reason = body.reason;
		} catch {
			// Not JSON — a proxy error page, most likely. The status text is the best we have.
		}
		throw new ApiError(response.status, reason, response.headers.get('X-Request-ID'));
	}

	if (response.status === 204) return undefined as T;
	return (await response.json()) as T;
}
