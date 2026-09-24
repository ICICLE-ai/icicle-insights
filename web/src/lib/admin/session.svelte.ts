import { ApiError } from '$lib/api/client';
import { auth } from '$lib/auth.svelte';
import { adminApi } from './api';

/**
 * Whether the held token belongs to an administrator, asked of the server.
 *
 * `GET /api/admins` is itself admin-only, so its answer is the check: 200 means admin, 401 means
 * the token did not verify (expired, wrong tenant), 403 means a valid user without admin rights.
 * The distinction matters to the person reading the sign-in screen, so it is kept.
 */
export type SessionState =
	| { status: 'anonymous' }
	| { status: 'checking' }
	| { status: 'admin' }
	| { status: 'unverified'; reason: string }
	| { status: 'forbidden'; reason: string }
	| { status: 'error'; error: unknown };

class AdminSession {
	state = $state<SessionState>({ status: 'anonymous' });
	#checked: string | null = null;

	/** Re-checks whenever the token changes; a no-op for a token already checked. */
	async verify(): Promise<void> {
		const token = auth.token;
		if (!token) {
			this.#checked = null;
			this.state = { status: 'anonymous' };
			return;
		}
		if (token === this.#checked && this.state.status !== 'error') return;

		this.#checked = token;
		this.state = { status: 'checking' };
		try {
			await adminApi.admins();
			if (auth.token === token) this.state = { status: 'admin' };
		} catch (error) {
			if (auth.token !== token) return;
			if (error instanceof ApiError && error.status === 401) {
				this.state = {
					status: 'unverified',
					reason:
						'This token did not verify. It may have expired or come from another Tapis tenant.'
				};
			} else if (error instanceof ApiError && error.status === 403) {
				this.state = {
					status: 'forbidden',
					reason: `${auth.claims.username ?? 'This account'} is signed in but is not an administrator of this deployment.`
				};
			} else {
				this.state = { status: 'error', error };
			}
		}
	}

	signOut(): void {
		auth.clear();
		this.#checked = null;
		this.state = { status: 'anonymous' };
	}
}

export const session = new AdminSession();
