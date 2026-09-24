# Set up the dashboard toolchain

Deno, the dev server, and the generated API types for the SvelteKit dashboard in `web/`. For
developers.

The dashboard is SvelteKit with shadcn-svelte components, TanStack Table, and charts drawn in SVG.
Deno runs everything; there is no separate Node install to manage.

## 1. Install Deno

```bash
brew install deno
```

Use Deno 2.9 or later. CI and the Dockerfile pin the exact version.

## 2. Install and run

```bash
just web-install
```

```bash
just web
```

The dev server runs on http://localhost:5174 and proxies `/api` to Vapor on port 8080. Start the API
separately with `just run`.

To proxy somewhere else, set `INSIGHTS_API` before `just web`:

```bash
INSIGHTS_API=http://127.0.0.1:9090 just web
```

## 3. Regenerate the API types after a server change

With the API running:

```bash
just web-types
```

This rewrites `web/src/lib/api/schema.d.ts` from `/openapi.json`. Never edit that file by hand.

## 4. Add a UI component

Components are copied into `web/src/lib/components/ui/` rather than installed, so they can be edited.

```bash
cd web && npx shadcn-svelte@latest add accordion
```

The CLI officially supports Node, not Deno, which is why this one step uses `npx`.

## Verify

```bash
just web-check
```

```bash
just web-test
```

```bash
just web-build
```

#icicle-insights# #How-To# #Developer# #frontend# #tooling#
