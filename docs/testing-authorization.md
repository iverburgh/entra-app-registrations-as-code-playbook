# Testing authorization

Authorization code fails silently. A missing policy does not throw; it lets everyone in. A wrong
role value does not throw; it locks everyone out, which you notice, or lets nobody but an
administrator in, which you might not. Tests are the only way to know.

The [sample API's tests](../samples/tests/Orders.Api.Tests/) run the real API in memory, with its
real authentication and authorization setup, against tokens they issue themselves. No tenant, no
network, under a second.

```powershell
dotnet test samples/Orders.slnx
```

## Issue your own tokens

[TestTokens.cs](../samples/tests/Orders.Api.Tests/TestTokens.cs) plays the part of Entra ID. It
generates an RSA key, and signs tokens with the claims Entra ID would put in them: `iss`, `aud`,
`oid`, `tid`, and `scp` or `roles`.

```csharp
TestTokens.User(AppRoles.OrdersRead)                    // delegated, scp access_as_user
TestTokens.Application(AppRoles.OrdersProcess)          // app-only, no scp
TestTokens.User(AppRoles.OrdersRead) with { Audience = "api://..." }   // one thing wrong
```

The tenant ID and application ID are generated per run. Tests then never contain a real identifier,
and cannot accidentally pass against a real tenant.

[OrdersApiFactory.cs](../samples/tests/Orders.Api.Tests/OrdersApiFactory.cs) starts the API with
`WebApplicationFactory` and points it at the test key instead of the authority's metadata endpoint:

```csharp
services.PostConfigure<JwtBearerOptions>(JwtBearerDefaults.AuthenticationScheme, options =>
{
    var configuration = new OpenIdConnectConfiguration { Issuer = TestTokens.Issuer };
    configuration.SigningKeys.Add(TestTokens.SigningKey);
    options.Configuration = configuration;
    options.ConfigurationManager = new StaticConfigurationManager<OpenIdConnectConfiguration>(configuration);
});
```

Set both. With only `Configuration`, the configured authority still makes the handler fetch
metadata from Entra ID.

Do not replace the authentication handler with one that accepts anything. Then the tests prove the
policies, but not the audience, issuer and signature checks, which are the part most often wrong.

## Every way a token can be wrong

[TokenValidationTests.cs](../samples/tests/Orders.Api.Tests/TokenValidationTests.cs). Start from a
token that is accepted, change one thing, expect `401`:

| Change                                          | Catches                                       |
| ----------------------------------------------- | --------------------------------------------- |
| no token, a malformed token                     | an endpoint without authentication            |
| expired an hour ago                             | lifetime validation switched off              |
| issuer of another tenant                        | issuer validation switched off, or multi-tenant by accident |
| v1 issuer `https://sts.windows.net/<tenant>/`    | a v1 token accepted                           |
| audience of another API                         | audience validation switched off              |
| audience `api://<appId>`                        | the v1 audience accepted next to the v2 one   |
| signed with another key                         | signature validation switched off             |

The test that a valid token *is* accepted matters as much: without it, a broken setup that rejects
everything passes all the others.

## Who may call what, as a table

[RoleMatrixTests.cs](../samples/tests/Orders.Api.Tests/RoleMatrixTests.cs) lists the kinds of callers
once, and per endpoint the ones that may call it:

```csharp
("GET",  "/orders",           ["reader", "administrator"]),
("POST", "/orders/1/cancel",  ["administrator"]),
("POST", "/orders/1/process", ["processing application"]),
```

Every endpoint is then called by every caller: the listed ones must succeed, all others must get
`403`. Include the callers that should never get through:

- a user without any role;
- a user with the right role but without the scope;
- a user with an application role, and an application with a user role.

A new endpoint gets tested against every caller by adding one line. A new kind of caller gets tested
against every endpoint. One more test checks that every name in the table is a known caller: a typo
would otherwise quietly mean "nobody may call this", and the test would pass.

## Every endpoint names who may call it

[EndpointConventionTests.cs](../samples/tests/Orders.Api.Tests/EndpointConventionTests.cs) reads the
endpoints from the running API (`EndpointDataSource`) and fails on any endpoint that:

- names no policy or role, so relies on the fallback policy; or
- allows anonymous access without a reason.

It also checks that it found endpoints at all, and is itself tested against endpoints built to break
the rule. A convention test that finds nothing passes forever.

For controllers, read the attributes by reflection instead; for Azure Functions, find the methods
with an `HttpTrigger` parameter and check them for `[Authorize]` or a justified exception.

## The same for Azure Functions

The isolated worker model runs the same ASP.NET Core middleware when you use
`ConfigureFunctionsWebApplication`. Test the authorization setup with the same tokens: either through
the Functions host in a test, or by running the policies directly with `IAuthorizationService` and a
`ClaimsPrincipal` built from the token's claims. The second is quicker and catches most mistakes;
the first also catches a missing middleware.

## The code matches the definition

[DefinitionContractTests.cs](../samples/tests/Orders.Api.Tests/DefinitionContractTests.cs) reads
`app-registrations.json` and compares the role and scope values of `orders-api` with the constants in
the code. Rename a role on one side only, and this test fails before anyone loses access.

## What not to test here

That Entra ID issues the right token for a user: that is the app registration and the
[role assignments](roles-and-members.md). Check it once per environment, by signing in.
