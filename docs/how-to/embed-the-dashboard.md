# Embed the dashboard

Put the dashboard in an iframe in another application. For administrators.

Three things must line up: the framing allowlist, the pod's networking, and how the parent hands
over a token.

## 1. Allow the embedding origin

```dotenv
FRAME_ANCESTORS=https://icicleai.tapis.io
```

Comma-separated. Origins only — scheme and host, no trailing path.

Unset, responses deny framing outright and the browser refuses the embed. That is the correct
default.

Setting this omits the legacy frame-options header entirely, because that header has no allowlist
form and could then only contradict the CSP directive.

Malformed entries are dropped with a warning rather than passed through. A policy the browser
rejects wholesale fails *open* on framing, so a typo must not become permission.

Restart after changing it.

## 2. Configure the pod

For a Tapis Pods deployment, the pod only needs to route traffic and stay out of the way of
authentication.

```json
{
  "networking": {
    "default": {
      "protocol": "http",
      "port": 8080,
      "tapis_auth": false,
      "tapis_ui_uri": "/",
      "tapis_ui_uri_redirect": false,
      "tapis_ui_uri_description": "ICICLE software impact and operations dashboard"
    }
  }
}
```

`tapis_auth: false` is the part that matters. The gateway passes everyone through and Insights
decides who may write, which is what keeps public reads working.

**Do not configure CORS at the pod.** Vapor owns it, from `CORS_ORIGINS`. Setting it in both places
means two layers emitting the same headers, and a browser rejects a response carrying a duplicated
allow-origin header outright.

## 3. Hand over a token

The dashboard holds a token in memory only. The parent sends it.

```js
frame.contentWindow.postMessage({ tapisToken: token }, INSIGHTS_ORIGIN);
```

Target the exact Insights origin, never `*`. The dashboard checks the sender's origin before
accepting anything.

Without a token the dashboard still renders fully, as a public dashboard. Administration features
appear only once a token arrives.

## Do you also need CORS?

Usually not.

| Situation | `CORS_ORIGINS` |
|---|---|
| The iframe calls its own pod | Leave unset. Requests are same-origin |
| The parent calls the API directly | Set it to the parent's origin |

Unset installs no CORS middleware at all, which is the right posture for a same-origin deployment.

## Confirm it worked

Load the parent page and open the browser console. A blocked frame reports a framing refusal
naming the policy. A working embed shows the dashboard, and the ADMIN chip appears once the parent
sends a token.

## Troubleshooting

**The frame is blank and the console mentions frame-ancestors.** `FRAME_ANCESTORS` does not include
the parent's origin, or the service was not restarted.

**The frame loads but stays anonymous.** The token never arrived. Check the parent targets the exact
Insights origin in its `postMessage`, and that the dashboard's expected parent origin matches.

**Cross-origin API calls arrive anonymous.** The browser is refusing to send the header. Add the
parent's origin to `CORS_ORIGINS`.

#icicle-insights# #How-To# #Administrator# #embedding#
