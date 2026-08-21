import { provideHttpClient, withFetch, withInterceptors } from '@angular/common/http';
import {
  ApplicationConfig,
  provideBrowserGlobalErrorListeners,
  provideZonelessChangeDetection,
} from '@angular/core';
import { provideRouter, withComponentInputBinding, withInMemoryScrolling } from '@angular/router';

import { provideOptimus } from '@openng/optimus-ui/config';
import Aura from '@openng/optimus-ui-themes/aura';

import { routes } from './app.routes';
import { authInterceptor } from './core/auth/auth-interceptor';
import { INSIGHTS_CONFIG, defaultInsightsConfig } from './core/config';

export const appConfig: ApplicationConfig = {
  providers: [
    provideBrowserGlobalErrorListeners(),
    provideZonelessChangeDetection(),

    provideRouter(
      routes,
      withComponentInputBinding(),
      // Deep links land at the top rather than wherever the previous view was scrolled to, and
      // a back navigation returns to where it left off.
      withInMemoryScrolling({ scrollPositionRestoration: 'enabled', anchorScrolling: 'enabled' }),
    ),

    // `withFetch` because the API is same-origin and streamed responses are not needed; it drops
    // the XHR backend from the bundle.
    provideHttpClient(withFetch(), withInterceptors([authInterceptor])),

    provideOptimus({
      theme: {
        preset: Aura,
        options: {
          // Class-based rather than the default `system`, because the theme has three states and
          // a media query can only express two. ThemeStore owns the class; index.html applies it
          // before first paint. All three must name the same selector.
          darkModeSelector: '.app-dark',
          // Component styles go into a named layer so Tailwind utilities can override them
          // without an escalating specificity fight. The order matches the `@layer` declaration
          // at the top of styles.css and has to, or the layer is created in the wrong position.
          cssLayer: {
            name: 'optimus',
            order: 'theme, base, optimus, components, utilities',
          },
        },
      },
    }),

    { provide: INSIGHTS_CONFIG, useValue: defaultInsightsConfig },
  ],
};
