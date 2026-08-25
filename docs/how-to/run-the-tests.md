# Run the tests

Get the suite passing locally. For developers.

```bash
just test
```

203 tests across 15 suites. Expect a few minutes; it runs serially by design.

## Two settings that are not optional

Get either wrong and the **entire** suite fails during setup, not one test. It reads like the code
is broken when it is not.

**`.env` must exist.**

```bash
cp .env.example .env
```

Tapis configuration is parsed inside `configure`, which every test that boots an app runs. A missing
file throws before any test body executes.

**`DATABASE_TLS=disable`**

The local PostgreSQL container serves no TLS. Without this, every connection fails with an SSL
error.

Dummy Tapis values are fine. The three tests needing real credentials skip themselves.

## Start the backing services

The suite needs PostgreSQL reachable on the default port.

```bash
container system start
```

```bash
just db
```

```bash
just valkey
```

Valkey is only needed for the suites that exercise rate limiting.

## Why it is serial

Every suite is `.serialized`, and `just test` adds `--no-parallel` on top.

Suites share the one `test` database and each migrates and reverts around itself. Any overlap has
one suite reverting the schema out from under another.

Several hardening tests also set process environment variables that `configure` reads at boot.
Process environment is global; running those concurrently would make them read each other's
settings.

**Do not remove `--no-parallel`.** The failures it prevents are intermittent and look like
unrelated bugs.

## Running a subset

```bash
swift test --no-parallel --filter AuthenticationTests
```

Keep `--no-parallel` even for one suite. It still migrates the shared database.

## Tests that reach real Tapis

Three vault tests write and destroy real secrets, because the adapter needs real credentials even to
fail usefully.

Point `.env` at the **staging** tenant and they run. Leave the token blank and they skip.

```dotenv
TAPIS_BASE_URL=https://icicleai.staging.tapis.io/v3
TAPIS_TENANT=icicleai
```

Staging is a separate vault, so nothing you run locally touches production.

The skip check reads the token's expiry, not just its shape. Tapis tokens last hours, so "looks like
a JWT" and "will authenticate" are different questions — an expired token would otherwise produce
confusing 500s indistinguishable from a real regression.

## Formatting

```bash
just fmt
```

```bash
just fmt-check
```

Run `just fmt` before committing. `swift-format` is authoritative.

## Dashboard tests

Separate toolchain, separate command:

```bash
just web-test
```

## Troubleshooting

**Every test fails in setup.** `.env` is missing, or `DATABASE_TLS` is not `disable`.

**Every connection fails with an SSL error.** `DATABASE_TLS=disable`.

**Intermittent failures about missing tables.** Something is running in parallel. Check for a
stray `swift test` without `--no-parallel`.

**Vault tests fail with 500s.** The Tapis token expired. Blank it out and they will skip instead.

## What the suite cannot catch

Testing skips the Tapis tenant key fetch and the vault keyset read, so anything on those paths is
invisible. Two real bugs hid there. Verify changes to those paths against staging, not just the
suite. See [Test suite](../reference/test-suite.md).

#icicle-insights# #How-To# #Developer# #testing#
