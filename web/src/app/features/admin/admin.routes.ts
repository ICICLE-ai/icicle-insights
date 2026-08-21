import { type Routes } from '@angular/router';
import { ConfirmationService, MessageService } from '@openng/optimus-ui/api';

import { AdminApi } from './admin-api';
import { AdminShell } from './admin-shell';
import { AdminStore } from './admin-store';

export const ADMIN_ROUTES: Routes = [
  {
    path: '',
    component: AdminShell,
    providers: [AdminApi, AdminStore, ConfirmationService, MessageService],
    children: [
      {
        path: '',
        loadComponent: () => import('./admin-overview').then((m) => m.AdminOverview),
        title: 'Operations console · ICICLE Insights',
      },
      {
        path: 'vaults',
        loadComponent: () => import('./vault-management').then((m) => m.VaultManagement),
        title: 'Vaults · ICICLE Insights',
      },
      {
        path: 'service-tokens',
        loadComponent: () =>
          import('./service-token-management').then((m) => m.ServiceTokenManagement),
        title: 'Service tokens · ICICLE Insights',
      },
      {
        path: 'administrators',
        loadComponent: () =>
          import('./administrator-management').then((m) => m.AdministratorManagement),
        title: 'Administrators · ICICLE Insights',
      },
      {
        path: 'catalog',
        loadChildren: () =>
          import('./catalog/catalog.routes').then((routes) => routes.CATALOG_ROUTES),
      },
    ],
  },
];
