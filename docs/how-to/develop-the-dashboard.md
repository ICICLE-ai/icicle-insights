# Develop the dashboard

How to run, check and build the SvelteKit dashboard in `web/`, for developers. The explanation is in
[The dashboard](../explanation/the-dashboard.md).

## Before you start

- [Deno](https://deno.com) 2.9. CI and the Dockerfile use 2.9.7.
- The API running on port 8080, from `just run`. See
  [Run Insights locally](../tutorials/run-insights-locally.md).

## Run it

```bash
just web-install   # deno install --frozen, exactly as deno.lock records
just web           # http://localhost:5174
```

The dev server forwards `/api` and `/openapi.json` to `http://127.0.0.1:8080`. Set `INSIGHTS_API`
to use an API on another local port.

## Check it before a pull request

```bash
just web-check && just web-test && just web-build
```

These run type checks, unit tests and the static build into `web/build`. CI runs the same three.

## Regenerate the API types

After changing a route or a DTO on the server, regenerate the TypeScript types from the running API:

```bash
just run           # in one terminal
just web-types     # in another; writes web/src/lib/api/schema.d.ts
```

Screens import types from `$lib/api/types`, which re-exports the generated schema.

## Add a shadcn-svelte component

```bash
cd web
deno run -A npm:shadcn-svelte@1.7.0 add tooltip
```

Components land in `src/lib/components/ui/`. The style settings are in `web/components.json`.

## Add a dependency

```bash
cd web
deno add -D npm:some-package
```

Everything the dashboard uses is a dev dependency, because the build output is static. Commit both
`package.json` and `deno.lock`. The Docker build runs `deno install --frozen` and fails if the lock
file is stale.

#icicle-insights# #How-To# #Developer#
