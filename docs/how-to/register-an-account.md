# Register an account

Add a platform account and the credential its collection needs. For administrators.

An account is an identity on a hosting platform. It owns resources and holds at most one vault
credential. Register the account first; resources attach to it afterwards.

## Add the account

1. Open **Administration → Catalog → Accounts**.
2. Select **Add account**.
3. Enter the account name exactly as the platform spells it.
4. Choose the registry: GitHub, GHCR, Hugging Face, npm, or PyPI.
5. Save.

The registry decides which API collects for every resource under this account. It is not the same
as a resource's kind — a container image and a repository can both sit under a GitHub account.

## Add its credential

Collection needs a token from the platform, with read access to its metrics API and repositories.
Without one, every sweep for this account fails as a credential error.

1. Create the token on the platform.
2. Open **Administration → Vaults**.
3. Select **Add credential**.
4. Choose the account, paste the token, and set an expiry date matching the one on the platform.
5. Save.

The credential name is generated from the account and its registry. You do not choose it.

The token goes to Tapis Vault. Only its name, account, and expiry are stored here, and the value is
never shown again. Setting the expiry is what lets the screen warn you before collection breaks.

Only accounts that do not already have a credential appear in the picker.

## Confirm it worked

The Accounts screen shows **Configured** in the Vault column.

To prove the credential actually works, add one resource and collect it — see
[Add a resource](add-a-resource.md) and
[Run collection immediately](run-collection-immediately.md).

## Rotating later

Rotate on the platform first, then use **Rotate** on the Vaults screen to store the new value.
The next sweep picks it up; there is no restart and no backfill needed.

If the credential lapses before you rotate, collection for every resource under that account fails
at once and re-books hourly. Fix the credential and it resumes unattended.

## Notes

- One credential per account. Resources inherit it.
- GHCR, npm, and PyPI accounts can be registered but are not collected yet. They need no credential.
- Deleting an account deletes its resources and their history. There is no undo.

#icicle-insights# #How-To# #Administrator# #catalog#
