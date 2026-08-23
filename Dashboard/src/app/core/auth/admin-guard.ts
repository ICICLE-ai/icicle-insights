import { toObservable } from '@angular/core/rxjs-interop';
import { inject } from '@angular/core';
import { type CanMatchFn, Router } from '@angular/router';
import { filter, map, take } from 'rxjs';

import { SessionStore, type SessionStatus } from './session-store';

/**
 * Keeps the administration bundle out of anonymous and non-admin sessions.
 *
 * Waiting through `unknown` matters for embedded TapisUI: a token can arrive just after the
 * shell paints, and redirecting before the server has assessed it would turn a valid admin into
 * a false access-denied screen. The server's `/admins` response remains the authority; no JWT
 * claim grants access here.
 */
export const adminGuard: CanMatchFn = () => {
  const session = inject(SessionStore);
  const router = inject(Router);

  return toObservable(session.status).pipe(
    filter((status): status is Exclude<SessionStatus, 'unknown'> => status !== 'unknown'),
    take(1),
    map((status) =>
      status === 'admin'
        ? true
        : router.createUrlTree(['/admin-access'], { queryParams: { state: status } }),
    ),
  );
};
