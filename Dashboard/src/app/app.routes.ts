import { Routes } from '@angular/router';

import { adminGuard } from './core/auth/admin-guard';

export const routes: Routes = [
  {
    path: '',
    // Lazy even though it is the landing route: it keeps the dashboard's charts and the d3
    // geometry they pull in out of the initial chunk, so the shell paints before any of it
    // has parsed.
    loadComponent: () => import('./features/dashboard/dashboard').then((m) => m.Dashboard),
    title: 'ICICLE Insights',
  },
  {
    path: 'admin-access',
    loadComponent: () => import('./features/admin-access/admin-access').then((m) => m.AdminAccess),
    title: 'Admin access · ICICLE Insights',
  },
  {
    path: 'admin',
    canMatch: [adminGuard],
    loadChildren: () => import('./features/admin/admin.routes').then((m) => m.ADMIN_ROUTES),
  },
  {
    path: '**',
    loadComponent: () => import('./features/not-found/not-found').then((m) => m.NotFound),
    title: 'Not found · ICICLE Insights',
  },
];
