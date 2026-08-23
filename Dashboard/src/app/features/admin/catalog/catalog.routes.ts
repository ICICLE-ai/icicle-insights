import { type Routes } from '@angular/router';

import { CatalogShell } from './catalog-shell';

export const CATALOG_ROUTES: Routes = [
  {
    path: '',
    component: CatalogShell,
    children: [
      {
        path: '',
        loadComponent: () => import('./account-management').then((m) => m.AccountManagement),
        title: 'Accounts · ICICLE Insights',
      },
      {
        path: 'resources',
        loadComponent: () => import('./resource-management').then((m) => m.ResourceManagement),
        title: 'Resources · ICICLE Insights',
      },
      {
        path: 'releases',
        loadComponent: () => import('./release-management').then((m) => m.ReleaseManagement),
        title: 'Releases · ICICLE Insights',
      },
      {
        path: 'metrics',
        loadComponent: () => import('./metric-management').then((m) => m.MetricManagement),
        title: 'Metrics · ICICLE Insights',
      },
    ],
  },
];
