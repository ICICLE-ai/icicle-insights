# Access and sign-in

Who can read and change what in Insights, and how the server decides. For administrators and
developers.

## Reading is open to everyone

Every figure on the dashboard is public, and so is almost every read in the API. The exceptions are
the lists of stored credentials, administrators and service tokens, and the operations views. Nobody
signs in to look at the dashboard.

Opening the reads was deliberate. The data describes public repositories and registries, and the
dashboard is meant to be embedded and shared. Requests are still limited per client address, so an
anonymous client cannot flood the API.

## Two kinds of caller can write

**Administrators** are people. They prove who they are with a Tapis token from the deployment's
tenant, and the server checks the token's signature against the tenant's public key. The key is
fetched once at startup, so no request waits on Tapis. A token from another tenant, even a validly
signed one, is ignored.

**Services** are deployed ICICLE programs that report their own usage. They carry a service token
that Insights issued. It names one resource and may only post readings to that resource.

Both kinds of token arrive the same way, as a bearer token. The server tries both checks on every
request, and neither check ever turns a request away. Each simply recognises its own kind of token
or stays silent. A request with no recognisable token continues anonymously.

## Rules decide, not the sign-in

Only the route itself refuses a request. A route that changes the catalog requires an
administrator. The service reporting route accepts an administrator, or the one service its token
names. An unrecognised caller gets 401. A recognised caller without permission gets 403. Neither
answer says which token was tried or why it failed.

## Who is an administrator

Administrators are Tapis usernames stored in the database. They are managed from the console and
take effect on the next request.

One username is special: `ROOT_ADMIN_USERNAME` from the deployment's configuration. It is always an
administrator, whatever the table says, and the console cannot remove it. If every other
administrator is deleted by mistake, the root can still sign in and restore them.

## How the dashboard gets a token

The dashboard never stores a token. It holds one in memory, from one of three places:

1. **TapisUI's `X-Tapis-Token` cookie**, readable because both sites share a parent domain.
2. **A message from TapisUI** when the dashboard is framed inside it, accepted only from origins
   fixed at build time.
3. **A token pasted** on the console's sign-in screen.

Holding a token proves nothing by itself. The console asks the server whether its holder is an
administrator before showing anything. The username and expiry in the sidebar are read from the
token only for display.

## Service tokens

Service tokens are signed by Insights with keys kept in Tapis Vault, apart from the key used for
Tapis tokens. Each token records the resource it may write to, a label and an expiry of up to a
year.

The database keeps a record of each token but never its value. A token is shown once, when issued.
Revoking it takes effect on its next request. Issuing a new token for a service revokes the old
one, so each service holds one live token.

Rotating the signing key adds a new key and keeps the old ones. Existing tokens keep working until
they expire, so rotation never takes a service offline.

#icicle-insights# #Explanation# #Administrator# #Developer#
