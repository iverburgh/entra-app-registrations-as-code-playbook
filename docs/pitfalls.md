# Pitfalls

## Renaming creates a new application

An application is found by its display name. Change `displayName` in the definition, or the
convention behind its tokens, and the next run finds nothing by the new name and creates a new
application. The old one stays, unmanaged, with its credentials and assignments.

To rename: rename the application in the portal first, then change the definition. The plan should
show no `create application`.

## Two applications with the same name

Entra ID allows it; the script refuses, because it cannot tell which one is meant:

```text
There are 2 applications named 'orders-api-test'. Display names identify applications here;
remove or rename the duplicates.
```

## Changing the value of a role is not a rename

Roles and scopes are matched by `value`. Change `Orders.Read` to `Orders.View` and the script
removes the old role and adds a new one, with a new ID. Assignments on the old role are gone; the
new role gets the members listed for it in the environment file. Admin consent that other
applications had for the old role is gone too, and your code still checks for the old value.

Add the new role, move code and members over, then remove the old one.

## `[]` is not the same as absent

`"appRoles": []` removes every role of the application. No `appRoles` key leaves the roles alone.
The same holds for `scopes`, `requiredResourceAccess`, `preAuthorizedApplications` and
`knownClientApplications`.

## Nested groups do not get roles

A group assigned to a role passes it on to its direct members only. Members of a group inside that
group do not get the role. Owners are different: there the script expands nested groups itself.

Group-based assignment also requires Microsoft Entra ID P1 or P2. Without it, assign users.

## A managed identity in a group gets nothing

App-only tokens do not carry roles assigned through groups. The script works around this by
assigning service principals found in a listed group directly. It only does so when the role
allows applications; for a role that only allows users, they are skipped.

## A typo stops the run, on purpose

A name that cannot be found stops the run. `-AllowUnresolvedPrincipals` skips it instead, and then
the role assignments of that name are *removed*, because they are no longer in the desired list. Use
it only for a first run, when you know which groups do not exist yet.

## Assignment required locks people out

Every service principal gets *assignment required* by default. Anyone without a role, developers
included, gets an error at sign-in (`AADSTS50105`). Put them in the file, or set
`"assignmentRequired": false` for that application.

## The audience of a v2 token is a GUID

The script sets `requestedAccessTokenVersion` to 2. A v2 access token has the application ID in
`aud`, not the identifier URI `api://<appId>`. An API that validates `api://...` rejects every
token. Accept the application ID as audience.

## `credential reset` without `--append`

`az ad app credential reset` replaces every credential of the application unless you pass
`--append`. The script always does; do the same in any renewal script.

## A lost client secret

Entra ID shows a secret's value once. If the copy in Key Vault is deleted, nobody can read it
again. The run warns; delete the client secret on the application and run again to get a new one.

## Entra ID is eventually consistent

Right after an application is created, another call can briefly not find it yet. If a first run in
an environment fails with "does not exist" or "does not reference a valid application object", run
it again: everything already created is found and skipped, and the run continues where it stopped.

## Removing a definition does not delete the application

The script never deletes applications or service principals. Remove a definition and the
application stays, unmanaged. Delete it yourself when you are sure nothing uses it.

## Deleted identities leave Azure role assignments behind

Deleting a managed identity, service principal or group removes its app role assignments, but not
its Azure RBAC role assignments. Those stay as *Identity not found* and count toward the
per-subscription limit until deployments fail. Clean them up periodically, but never on the word of
the assignment list alone. See
[Roles and members](roles-and-members.md#azure-rbac-assignments-left-behind).

## The pipeline's permissions are an administrator's

`AppRoleAssignment.ReadWrite.All` lets its holder grant itself any permission. Protect the service
connection accordingly. See [Running in a pipeline](running-in-a-pipeline.md#these-permissions-are-powerful).

## In your code

### The fallback policy lets every signed-in caller in

A fallback policy of `RequireAuthenticatedUser()` protects endpoints that declare nothing against
anonymous callers, and against nobody else. Any account in the tenant with any role, and any
application with a token for your API, passes it. Give every endpoint a policy, and test that it
does. See [Securing your API](securing-your-api.md#the-fallback-policy-is-not-authorization).

### Roles without the scope

A user policy that checks only `roles` accepts a token obtained by any client application the user
signs in to. Check the delegated scope (`scp`) too, and require an app-only token for application
roles.

### `scp` is one claim

The scopes in a delegated token are one claim, separated by spaces: `"access_as_user Orders.Export"`.
Comparing the whole claim with one scope works until a client asks for two. Split it.

### `roles` renamed

Without `MapInboundClaims = false`, ASP.NET Core renames `roles` to
`http://schemas.microsoft.com/ws/2008/06/identity/claims/role`, and code that reads `roles` finds
nothing. Turn the mapping off and set `RoleClaimType = "roles"`.

### `AZURE_CLIENT_ID` picks the identity

`DefaultAzureCredential` reads `AZURE_CLIENT_ID` and uses that user-assigned identity, even when it
was set for something else. Choose the identity in configuration, and create that credential. See
[Calling other services](calling-other-services.md#one-identity-chosen-explicitly).

### A confidential client per request

MSAL caches tokens in the client application object. Creating one per request throws the cache away,
and asks Entra ID for a new token on every call, until it throttles you. Create it once.

### Telemetry stops after disabling local authentication

Once local authentication is disabled on Application Insights, telemetry sent with the
instrumentation key is dropped without an error. Move every sender to Entra ID first, and check each
one. See [Calling other services](calling-other-services.md#application-insights-with-entra-id).

### A certificate that renews itself, until it cannot

An application can roll its own certificate without permissions, but only while one is still
valid. Once all have expired, a person has to step in. Alert on the expiry date. See
[Credentials](credentials.md#the-application-renews-its-own-certificate).

### A gateway that forwards the user's token

A reverse proxy copies the `Authorization` header by default. Put one in front of your APIs and the
SPA's token goes along to every API behind it, which then has to accept a token meant for something
else. Exchange it per route instead, and remove the original header first. See
[A gateway for a SPA](gateway-with-on-behalf-of.md#what-not-to-do).

### A health probe on an authenticated path

A load balancer that probes `/` takes the backend out of rotation as soon as `/` starts returning
401, and every user gets a 502. Give the probe its own anonymous endpoint, and test that it stays
anonymous. See [A gateway for a SPA](gateway-with-on-behalf-of.md#the-incident-a-probe-on-an-authenticated-path).

### Every 401 is "sign in again"

A SPA that answers every 401 with a new interactive sign-in loops when the 401 means something the
user cannot fix, such as an API rejecting the gateway's token. Act only on a challenge that says
what to do (`error="interaction_required"` or `"insufficient_claims"`), and let the gateway turn
other failures into a 502.
