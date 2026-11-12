# Securing your API

The app registration decides who can get a token. Your API decides what a token may do. This page
is about the second half: validating the token, and turning roles and scopes into decisions.

The examples come from the [sample API](../samples/), which matches the `orders-api` definition in
[app-registrations.json](../app-registrations/app-registrations.json).

## Two kinds of tokens

| Caller                                        | Token     | Carries                                   |
| --------------------------------------------- | --------- | ----------------------------------------- |
| A user, through a client application          | delegated | `scp` (the scopes consented) and `roles` (the user's app roles) |
| An application acting as itself               | app-only  | `roles` (the application permissions granted), never `scp` |

The `scp` claim is the difference. A user role in an app-only token, or an application role in a
delegated token, is a mistake in the assignments; the API should refuse it rather than trust it.

Both kinds have the user's or application's object ID in `oid` and the tenant in `tid`. Use `oid`
to identify a caller, never `name` or `preferred_username`: those can change, and can be the same
for two accounts.

## Validating the token

```csharp
options.Authority = "https://login.microsoftonline.com/<tenant-id>/v2.0";
options.TokenValidationParameters.ValidIssuer = "https://login.microsoftonline.com/<tenant-id>/v2.0";
options.TokenValidationParameters.ValidAudience = "<application ID of the API>";
options.MapInboundClaims = false;
options.TokenValidationParameters.RoleClaimType = "roles";
```

- **Audience.** The app registrations in this repository ask for v2 access tokens. A v2 token has the
  application ID in `aud`, not `api://<appId>`. Accept exactly that.
- **Issuer.** The v2 issuer ends in `/v2.0`. A v1 token (`https://sts.windows.net/<tenant>/`) is
  rejected, which is what you want: it means a client asked for the wrong token version.
- **Signature and lifetime** are checked by default, with the signing keys from the authority's
  metadata. Keep the default clock skew of five minutes.
- **Claim names.** By default ASP.NET Core renames `roles` to a long legacy URI. With
  `MapInboundClaims = false` the claims keep their names from the token, and `RoleClaimType = "roles"`
  makes `IsInRole` and `RequireRole` work.

See [AuthenticationSetup.cs](../samples/src/Orders.Api/Security/AuthenticationSetup.cs). It reads the
tenant and application ID from configuration, validates them at startup, and fails the start if they
are missing.

*Microsoft.Identity.Web* does the same with less code. Use it if you prefer; the decisions on this
page stay the same.

## Role values are constants

The value of a role is a contract between the definition file and the code. Keep them in one place:

```csharp
public static class AppRoles
{
    public const string OrdersRead = "Orders.Read";
    public const string OrdersAdmin = "Orders.Admin";
    public const string OrdersProcess = "Orders.Process";
}
```

A string typed in an attribute is a role nobody has, and the endpoint silently becomes unusable. A
constant can be found, and [checked against the definition file](testing-authorization.md#the-code-matches-the-definition)
in a test.

## One policy per kind of access

Name a policy for every kind of access, and make it say who the caller must be:

```csharp
options.AddPolicy(Policies.ReadOrders, policy => policy
    .RequireAuthenticatedUser()
    .RequireAssertion(context =>
        context.User.IsDelegated()
        && context.User.HasScope(AppScopes.AccessAsUser)
        && (context.User.IsInRole(AppRoles.OrdersRead) || context.User.IsInRole(AppRoles.OrdersAdmin))));

options.AddPolicy(Policies.ProcessOrders, policy => policy
    .RequireAuthenticatedUser()
    .RequireAssertion(context => !context.User.IsDelegated() && context.User.IsInRole(AppRoles.OrdersProcess)));
```

- A **user policy** requires a delegated token, the scope the client was consented for, and the role.
  Without the scope check, any client application that can get a token for the user can call it.
- An **application policy** requires an app-only token and the role.
- `scp` is a single claim with the scopes separated by spaces. Split it; a `HasClaim("scp", ...)`
  comparison fails as soon as a client asks for two scopes.

See [Policies.cs](../samples/src/Orders.Api/Security/Policies.cs).

## The fallback policy is not authorization

```csharp
options.FallbackPolicy = new AuthorizationPolicyBuilder().RequireAuthenticatedUser().Build();
```

The fallback policy applies to every endpoint that declares nothing. It guarantees that the caller
has a valid token. It does not check a single role: every user in the tenant, and every application
that can get a token for your API, passes it. With *assignment required* on, that set is smaller,
but still everyone with *any* role.

So keep the fallback policy as a safety net, and never rely on it. Every endpoint either names a
policy, or is anonymous on purpose:

```csharp
orders.MapGet("/", ...).RequireAuthorization(Policies.ReadOrders);
app.MapGet("/health", ...).AllowAnonymousBecause("Platform health probes carry no token.");
```

`AllowAnonymousBecause` is a small extension in the sample that adds the reason as metadata. A
convention test fails on any endpoint that names no policy, or allows anonymous access without a
reason. See [Testing authorization](testing-authorization.md#every-endpoint-names-who-may-call-it).

A bare `[Authorize]` counts as declaring nothing: it requires a signed-in caller, just like the
fallback.

### Or enforce it at compile time

The same rule can be a Roslyn analyzer: a warning (an error, with `TreatWarningsAsErrors`) on every
controller action or Functions trigger without an authorization attribute. A suppression then needs a
justification in the code:

```csharp
[SuppressMessage("Security", "API001:Endpoint requires authorization",
    Justification = "Called by the platform's health probe, which carries no token.")]
```

An analyzer catches the mistake earlier; a convention test is less work to write and also sees
endpoints added at run time. Either works. Not checking at all does not: an endpoint without a
policy looks exactly like one with a policy until someone without a role calls it.

## Azure Functions

The isolated worker model has no authorization by default: a function with an `HttpTrigger` and
`AuthorizationLevel.Anonymous` is open to anyone who can reach it. With ASP.NET Core integration
(`ConfigureFunctionsWebApplication`), add the authentication and authorization middleware yourself,
with the same JWT bearer setup and the same fallback policy, and give each function a policy:

```csharp
[Function("ProcessOrder")]
[Authorize(Policy = Policies.ProcessOrders)]
public Task<IActionResult> Run([HttpTrigger(AuthorizationLevel.Anonymous, "post")] HttpRequest request) => ...
```

`AuthorizationLevel.Function` (a function key) is not authorization either: a key is a shared
password that identifies nobody. Use it, if at all, in addition to a token.

## The user interface is not the security boundary

A front end can hide a button for users without the role; read the roles from the ID token or ask
the API. That is convenience. The API decides, on every request, as if the front end did not exist:
anyone can call it with a token and a tool.

## Checklist

- The audience is the application ID; the issuer ends in `/v2.0`.
- Claims keep their names; `RoleClaimType` is `roles`.
- Role and scope values are constants, matching the definition file.
- User policies check the scope and require a delegated token; application policies require an
  app-only token.
- Every endpoint names a policy or is anonymous for a stated reason, and a test or analyzer enforces
  it.
- Callers are identified by `oid`.
