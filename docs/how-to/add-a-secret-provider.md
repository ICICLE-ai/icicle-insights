# Add a secret provider

Store platform credentials in a different backend. For developers.

The contract is three operations over named secrets:

```swift
protocol SecretProvider: Sendable {
  func readSecret(named name: String) async throws -> Secret
  func writeSecret(named name: String, secret: String) async throws
  func destroySecret(named name: String) async throws
}
```

## Steps

### 1. Create the adapter

`Sources/Insights/Services/<Provider>/<Provider>SecretProvider.swift`

Conform to `SecretProvider`. Keep backend authentication, payload shapes, and error translation
inside the adapter. Nothing outside it should know which backend is in use.

### 2. Wrap every value in `Secret`

```swift
return Secret(value)
```

`Secret` redacts description, debug output, and reflection. Returning a bare `String` puts
credentials one interpolation away from a log line.

### 3. Validate configuration eagerly

Give the adapter a `fromEnvironment` that throws on anything missing. Failing at boot is far better
than failing inside a job three days later.

### 4. Add one case to the composition root

In `configure.swift`:

```swift
case "example":
  app.secrets = try ExampleSecretProvider.fromEnvironment(client: app.client)
```

That is the only place a concrete backend is named. An unsupported value already fails at boot.

### 5. Translate errors for both boundaries

Errors cross two boundaries with different needs.

| Boundary | Needs |
|---|---|
| HTTP, via the vault routes | An `AbortError` with a status and a reason that excludes credentials |
| Queues, via job failure handling | To be classifiable as a credential failure, so it alerts and re-books |

Map upstream 5xx to 502 and upstream 4xx to 500. The caller did not cause an upstream fault, and
neither status should leak a credential into its reason.

### 6. Test it

Cover six cases against a stubbed HTTP client:

- success
- not found
- authentication failure
- malformed response
- write
- destroy

Job tests stay provider-neutral. They use `InMemorySecrets`, and should keep doing so — that is what
proves the seam holds.

## Read-only backends

Environment variables and mounted Kubernetes Secrets can be read but not written.

Do not silently succeed on a write. Either throw a documented unsupported-operation error, or split
the contract into a reader and a writer before adding the adapter. A write that appears to work and
does not is worse than one that fails.

## Switching a deployment over

Changing the setting changes where lookups go. **It does not migrate anything.**

1. Provision the same secret names in the destination backend.
2. Verify reads against the destination.
3. Switch the setting and restart.
4. Keep the previous backend available through the rollback window.

Existing `vaults` rows keep working unchanged, because they store names rather than values.

## Verify

```bash
just test
```

Then check a real collection resolves a credential:

```bash
just collect --force
```

Watch the worker log. A credential failure is logged at `critical` and names the secret.

## Then

Update [Configuration](../reference/configuration.md) with the new provider's variables.

#icicle-insights# #How-To# #Developer# #credentials#
