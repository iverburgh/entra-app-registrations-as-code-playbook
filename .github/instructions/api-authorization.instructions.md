---
applyTo: '**/*.cs'
---

# API authentication and authorization

- Validate v2 tokens: the audience is the API's application ID (not `api://<appId>`), the issuer is
  `https://login.microsoftonline.com/<tenant>/v2.0`. Read both from configuration; fail at startup
  when they are missing.
- Set `MapInboundClaims = false` and `RoleClaimType = "roles"`. Identify callers by `oid`, never by
  `name` or `preferred_username`.
- Role and scope values are constants in one class, equal to the values in
  `app-registrations/app-registrations.json`. Never type a role value as a string literal elsewhere.
- Every endpoint names a policy (`RequireAuthorization(Policies.X)`, `[Authorize(Policy = ...)]`) or
  is anonymous with a stated reason (`AllowAnonymousBecause("...")`). A bare `[Authorize]` and the
  fallback policy are not authorization: they admit every signed-in caller.
- User policies require a delegated token (`scp` present), the consented scope and the role.
  Application policies require an app-only token (no `scp`) and the role. Split `scp` on spaces.
- Add a new endpoint to the role matrix in the tests, with every caller that may use it. Never
  replace the authentication handler in tests; issue signed test tokens instead.
- Choose the Azure identity explicitly (`ManagedIdentity:Type`, `ManagedIdentity:ClientId`); use
  `DefaultAzureCredential` only for local development, without managed identity and environment
  credentials. One `TokenCredential` for all Azure SDK clients.
- Never forward an incoming token to another API; exchange it on behalf of the user, with one scope
  per downstream API. Create the MSAL confidential client once.
- Never log a token, a certificate or a client secret.
