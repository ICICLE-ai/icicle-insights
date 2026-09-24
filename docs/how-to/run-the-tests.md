# Run the tests

How to run the server and dashboard test suites locally without touching production. For
developers.

## Server tests

1. Make sure PostgreSQL and Valkey are running on `localhost`. See
   [Run Insights locally](../tutorials/run-insights-locally.md).
2. Create the `test` database once. The suite always uses it, whatever `.env` says:

   ```bash
   docker compose exec db psql -U vapor_username -d vapor_database -c 'CREATE DATABASE test'
   ```

   On the Apple Container stack, use `container exec db` instead of `docker compose exec db`.
3. Check `.env` points at the **staging** tenant, `https://icicleai.staging.tapis.io/v3`. A few
   vault tests write real secrets when `TAPIS_TOKEN` is a real token.
4. Run the suite:

   ```bash
   just test
   ```

The suite runs serially because every test suite migrates and reverts the one `test` database.

## Dashboard tests

```bash
just web-check    # svelte-check and TypeScript
just web-test     # vitest
```

## In a container

`just stack-test` runs the server suite inside the Apple Container network, against the stack's own
database and Valkey. Use it when native tests fail with `Connection refused` to Valkey: on macOS,
`localhost` can resolve to IPv6 first while the published ports are IPv4 only.

## What CI runs

The same commands, on every pull request to `main` or `dev`. CI uses a placeholder
`TAPIS_TOKEN` that is not a JWT, so the vault tests skip themselves. See
[CI pipeline](../reference/ci-pipeline.md).

## Formatting

```bash
just fmt-check    # report problems
just fmt          # fix them
```

#icicle-insights# #How-To# #Developer#
