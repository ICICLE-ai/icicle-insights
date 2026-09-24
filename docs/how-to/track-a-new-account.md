# Track a new account

How to add an organisation or user on a platform, and give Insights the token it needs to read
it. For administrators signed in to the console.

## 1. Add the account

1. Open **Accounts** and click **Add account**.
2. Choose the **Platform**.
3. Type the **Name** exactly as the platform spells it. For GitHub that is the organisation in
   `github.com/{name}`. For Hugging Face it is the user or organisation in `huggingface.co/{name}`.
   Names are stored lowercase.
4. Click **Add account**.

## 2. Store a token, for GitHub and Hugging Face

GitHub and Hugging Face accounts are only read with a token. Patra and GHCR pages are public, so
skip this step for them.

1. Create a read-only token on the platform:
   - **GitHub:** the traffic figures need a token with push access to the repositories.
   - **Hugging Face:** a *read* access token is enough.
2. Open **Vaults** and click **Add credential**.
3. Choose the **Account**. Only accounts without a credential are listed.
4. Paste the **Token** and set **Expires on** to the token's real expiry date.
5. Click **Store credential**.

The token goes to Tapis Vault and is never shown again. Nothing warns you when it nears its
expiry, so note the date. See [Replace a platform token](replace-a-platform-token.md).

## 3. Add what to track

- **GitHub, Hugging Face, GHCR:** add each repository, model, dataset or container. See
  [Add a resource](add-a-resource.md).
- **Patra:** nothing to add. The daily catalog sweep at 04:00 registers every public model card and
  datasheet as a resource.

## Check it worked

- **Accounts** lists the account. For GitHub and Hugging Face, **Credential** says *Stored in vault*.
- After you add resources, **Operations** shows no new **Recent failures**. A `missing_token` failure
  means step 2 was skipped.

#icicle-insights# #How-To# #Administrator#
