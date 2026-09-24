/**
 * The administrator's Tapis token, held in memory only.
 *
 * Never persisted: a token in `localStorage` outlives the session that issued it and is readable
 * by any script on the origin. A reload therefore signs the administrator out, unless the token
 * arrives again from one of the three places below — which is the point of listening to them.
 *
 * - The `X-Tapis-Token` cookie, which TapisUI sets for pages it serves on the same site.
 * - A `postMessage` from the parent frame when the dashboard is embedded (see
 *   docs/how-to/embed-the-dashboard.md). Only from an origin in `trustedParentOrigins`, and only
 *   from `window.parent` itself — not from any other window that happens to share that origin.
 * - A token pasted by hand on the sign-in screen.
 *
 * The server decides what the token is worth. Holding one only means requests carry it; whether
 * its owner is an administrator is `GET /api/admins` answering 200 rather than 401/403.
 */

export type TokenSource = 'cookie' | 'message' | 'manual';

const COOKIE_NAME = 'X-Tapis-Token';

/**
 * Parent origins allowed to hand over a token, set at build time.
 *
 * The Angular dashboard had this list too, but nothing ever set it, so an embedded dashboard could
 * never receive a token. It defaults to TapisUI's origin, the same origin the embedding guide puts
 * in `FRAME_ANCESTORS`; override with a comma-separated `VITE_TRUSTED_PARENT_ORIGINS`.
 */
const trustedParentOrigins: readonly string[] = (
	import.meta.env.VITE_TRUSTED_PARENT_ORIGINS ?? 'https://icicleai.tapis.io'
)
	.split(',')
	.map((origin: string) => origin.trim())
	.filter(Boolean);

class AuthStore {
	token = $state<string | null>(null);
	source = $state<TokenSource | null>(null);

	#listening = false;

	/** Reads the cookie and starts listening for the parent frame. Safe to call more than once. */
	initialize(): void {
		const fromCookie = readCookie(COOKIE_NAME);
		if (fromCookie && !this.token) {
			this.set(fromCookie, 'cookie');
		}

		if (this.#listening || typeof window === 'undefined') return;
		this.#listening = true;

		window.addEventListener('message', (event: MessageEvent) => {
			if (event.source !== window.parent || window.parent === window) return;
			if (!trustedParentOrigins.includes(event.origin)) return;

			const token = (event.data as { tapisToken?: unknown } | null)?.tapisToken;
			if (typeof token === 'string' && token.trim()) {
				this.set(token.trim(), 'message');
			}
		});
	}

	set(token: string, source: TokenSource): void {
		const trimmed = token.trim();
		this.token = trimmed || null;
		this.source = trimmed ? source : null;
	}

	clear(): void {
		this.token = null;
		this.source = null;
	}

	/**
	 * The username and expiry the token claims, decoded without verification.
	 *
	 * Display only — the server verifies the signature on every request. Decoding here just lets the
	 * header say who is signed in and warn before the token lapses, without another round trip.
	 */
	get claims(): { username: string | null; expiresAt: Date | null } {
		return decodeClaims(this.token);
	}
}

export const auth = new AuthStore();

function readCookie(name: string): string | null {
	if (typeof document === 'undefined') return null;
	const prefix = `${name}=`;
	for (const entry of document.cookie.split(';')) {
		const trimmed = entry.trim();
		if (!trimmed.startsWith(prefix)) continue;
		const raw = trimmed.slice(prefix.length);
		try {
			return decodeURIComponent(raw) || null;
		} catch {
			return raw || null;
		}
	}
	return null;
}

export function decodeClaims(token: string | null): {
	username: string | null;
	expiresAt: Date | null;
} {
	const payload = token?.split('.')[1];
	if (!payload) return { username: null, expiresAt: null };
	try {
		const json = JSON.parse(atob(payload.replace(/-/g, '+').replace(/_/g, '/')));
		return {
			username: typeof json['tapis/username'] === 'string' ? json['tapis/username'] : null,
			expiresAt: typeof json.exp === 'number' ? new Date(json.exp * 1000) : null
		};
	} catch {
		return { username: null, expiresAt: null };
	}
}
