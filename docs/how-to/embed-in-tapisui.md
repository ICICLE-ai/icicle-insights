# Embed the dashboard in TapisUI

How to show the dashboard inside TapisUI, with administrators signed in automatically. For
administrators who run the deployment. The production dashboard is already embedded at
<https://icicleai.tapis.io/#/insights>.

Two settings must agree: the server must allow framing, and the dashboard must trust the parent.

## 1. Allow framing on the server

Set `FRAME_ANCESTORS` on the API process to the TapisUI origin. Use the scheme and host, with no
trailing slash.

```bash
FRAME_ANCESTORS=https://icicleai.tapis.io
```

Unset, the server sends `X-Frame-Options: DENY` and `frame-ancestors 'none'`, and the frame stays
blank. Set, it sends `Content-Security-Policy: frame-ancestors 'self'` plus this list, and no
`X-Frame-Options`.

## 2. Trust the parent in the dashboard build

The dashboard accepts a token only from origins listed in `VITE_TRUSTED_PARENT_ORIGINS`. It is
fixed when the dashboard is built, and defaults to `https://icicleai.tapis.io`.

For a different TapisUI, build the image with the build argument:

```bash
docker build --build-arg VITE_TRUSTED_PARENT_ORIGINS=https://tapisui.example.org -t insights .
```

Separate several origins with commas.

## 3. Point TapisUI at the dashboard

TapisUI's own configuration adds the page and frames the dashboard's address, such as
`https://insights.pods.icicleai.tapis.io/`. That configuration lives outside this repository.

The dashboard picks up the signed-in user's token in either of two ways:

- **The `X-Tapis-Token` cookie.** TapisUI sets it, and the dashboard can read it when both sites share
  a parent domain, as `icicleai.tapis.io` and `insights.pods.icicleai.tapis.io` do.
- **A message from the parent frame** of the form `{ "tapisToken": "…" }`, accepted only from an
  origin in `VITE_TRUSTED_PARENT_ORIGINS`.

## Check it worked

1. Sign in to TapisUI and open the Insights page.
2. The dashboard header shows your username instead of **Admin**.
3. As an administrator, click it. The console opens without asking for a token.

If the frame is blank, check `FRAME_ANCESTORS`. If the header still says **Admin**, check
`VITE_TRUSTED_PARENT_ORIGINS` in the build.

#icicle-insights# #How-To# #Administrator#
