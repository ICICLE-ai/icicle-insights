<!--
  The Angular Best Practices section below is Angular's own published guidance, from
  https://angular.dev/assets/context/best-practices.md

  Refresh it from that URL after an Angular major version rather than editing it by hand:

      curl -o /tmp/best-practices.md https://angular.dev/assets/context/best-practices.md

  The "ICICLE Insights specifics" section at the end is ours. Put project rules there.
  The Angular CLI MCP server also serves this guidance via its get_best_practices tool —
  see docs/how-to/set-up-the-dashboard-toolchain.md
-->

You are an expert in TypeScript, Angular, and scalable web application development. You write functional, maintainable, performant, and accessible code following Angular and TypeScript best practices.

## TypeScript Best Practices

- Use strict type checking
- Prefer type inference when the type is obvious
- Avoid the `any` type; use `unknown` when type is uncertain

## Angular Best Practices

- Always use standalone components over NgModules
- Must NOT set `standalone: true` inside Angular decorators. It's the default in Angular v20+.
- Do NOT set `changeDetection: ChangeDetectionStrategy.OnPush` explicitly. `OnPush` is the default in Angular v22+.
- Use signals for state management
- Implement lazy loading for feature routes
- Do NOT use the `@HostBinding` and `@HostListener` decorators. Put host bindings inside the `host` object of the `@Component` or `@Directive` decorator instead
- Use `NgOptimizedImage` for all static images.
  - `NgOptimizedImage` does not work for inline base64 images.

## Accessibility Requirements

- It MUST pass all AXE checks.
- It MUST follow all WCAG AA minimums, including focus management, color contrast, and ARIA attributes.

### Components

- Keep components small and focused on a single responsibility
- Use `input()` and `output()` functions instead of decorators
- Use `model()` for two-way bound properties with `[(prop)]` syntax instead of pairing `input()` with `output()`
- Use `computed()` for derived state
- Use `linkedSignal()` for state derived from multiple reactive sources that must stay synchronized
- Prefer inline templates for small components
- Prefer Signal Forms (`@angular/forms/signals`) for new forms. They are stable in Angular v22+ and provide signal-based state, type-safe field access, and schema-based validation
- When not using Signal Forms, prefer Reactive forms instead of Template-driven ones
- Do NOT use `ngClass`, use `class` bindings instead
- Do NOT use `ngStyle`, use `style` bindings instead
- When using external templates/styles, use paths relative to the component TS file.

## State Management

- Use signals for local component state
- Use `computed()` for derived state
- Keep state transformations pure and predictable
- Do NOT use `mutate` on signals, use `update` or `set` instead

## Templates

- Keep templates simple and avoid complex logic
- Use native control flow (`@if`, `@for`, `@switch`) instead of `*ngIf`, `*ngFor`, `*ngSwitch`
- Use the async pipe to handle observables
- Do not assume globals like (`new Date()`) are available.

## Services

- Design services around a single responsibility
- Use the `providedIn: 'root'` option for singleton services
- Prefer the `@Service` decorator over `@Injectable({providedIn: 'root'})` for new singleton services (Angular v22+)
- Use the `inject()` function instead of constructor injection

---

## ICICLE Insights specifics

Project rules. These sit on top of the Angular guidance above, and win where they overlap.

### Components

- Import Optimus UI components individually, per component, not from a barrel:
  `import { Button } from '@openng/optimus-ui/button';`
- Charts come from TanStack Charts. Do not add another charting dependency; the production build
  enforces bundle budgets and will fail.

### Authentication

- The Tapis token lives **in memory only**. Never write it to `localStorage`, `sessionStorage`, or
  a cookie.
- Resolution order is `postMessage` from an allowed parent origin, then a readable
  `X-Tapis-Token` cookie, then manual paste.
- Always check `event.origin` before accepting a `postMessage`. There is no exception to this.
- Send it as `Authorization: Bearer`. The server reads nothing else.
- Anonymous is a first-class state. The application must render fully for a signed-out visitor;
  administrator features are progressive enhancement, never a gate.
- The route guard decides what to render, never whether access is permitted. Authorization is
  always server-side.

### Accessibility

- Every chart needs an exact table alternative, keyboard support, and an accessible name.
- Must pass AXE in **both** light and dark themes.
- WCAG AA minimums, including focus management and colour contrast.

### Testing

- Vitest, not Karma or Jasmine. Run with `just web-test`.
- Test stores and pure functions directly. Reserve component tests for rendering and interaction.

### Layout

- The dashboard viewport is bounded and does not scroll. New content fits inside it or earns its
  place by displacing something.

### Reference

Server contract and rationale live in the repository's `docs/`:

- `docs/reference/http-api.md` — routes, guards, status codes, query parameters
- `docs/explanation/the-dashboard.md` — serving, tokens, CSP, why there is no SSR
- `docs/how-to/set-up-the-dashboard-toolchain.md` — MCP server and the vendor `llms-full.txt` files
