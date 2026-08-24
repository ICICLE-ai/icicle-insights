# Rotate the signing keyset

Roll the webhook signing key without breaking issued tokens. For administrators.

Rotation is additive. A new key becomes active for minting, retired keys stay registered for
verification, and tokens issued beforehand keep working until they expire. No restart, no flag day.

## Rotate

```bash
just token rotate-key
```

Or use **Rotate signing key** on the Administration → Service tokens screen.

## Confirm it worked

The boot log's `Webhook token signing keys loaded.` line reports a higher key count and a new active
identifier at the next restart. Until then, check that an existing service can still post a reading.

## Verify it properly

Only a restart proves the retired key was persisted rather than merely still in memory. The full
check is:

1. Mint a token and post a reading with it. Expect success.
2. Rotate.
3. **Restart the service.**
4. Post again with the *original* token. Expect success.

Skip the restart and you have proved nothing.

## When to rotate

- On a schedule, as routine hygiene.
- Whenever the keyset may have been exposed.
- After someone with vault access leaves.

Rotation does not invalidate anything, so it is safe to do often.

## What not to use

```bash
just token init-key --force
```

This **discards the keyset and invalidates every issued token at once**, taking every deployed
service offline until each is reissued. It exists for a deployment that must repudiate its keys
deliberately.

Use `rotate-key` for everything else.

## Notes

- Keys older than the longest possible token lifetime are dropped rather than accumulating.
- Rotation is safe at runtime; the key collection is concurrency-safe.
- Staging and production hold separate keysets in separate vaults. Rotating one does not touch the
  other.

#icicle-insights# #How-To# #Administrator# #credentials#
