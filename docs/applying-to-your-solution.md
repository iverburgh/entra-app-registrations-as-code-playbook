# Applying it to your solution

Most solutions already have app registrations, made by hand, slightly different per environment.
This page takes you from there to managed, without anyone losing access along the way.

The order matters: describe what exists, compare until the plan is boring, and only then let the
script remove things.

## 1. Copy the folder

Copy `app-registrations/` into your repository, and `pipelines/` if you use Azure DevOps. Delete
the example definitions and environment files, keep the schemas, the scripts and the tests.

## 2. Take stock

List what exists, per environment:

```powershell
az ad app list --filter "startswith(displayName,'orders')" --query "[].{name:displayName, appId:appId}" --output table
```

For each application, look at its roles, scopes, requested permissions and redirect URIs:

```powershell
az ad app show --id <appId> --query "{roles:appRoles, scopes:api.oauth2PermissionScopes, permissions:requiredResourceAccess, spa:spa, web:web}"
```

And who has which role:

```powershell
$sp = az ad sp list --display-name 'orders-api-prod' --query '[0]' | ConvertFrom-Json
$roles = @{}; $sp.appRoles | ForEach-Object { $roles[$_.id] = $_.value }
az rest --uri "https://graph.microsoft.com/v1.0/servicePrincipals/$($sp.id)/appRoleAssignedTo" --query value |
    ConvertFrom-Json | Select-Object @{ n = 'role'; e = { $roles[$_.appRoleId] } }, principalType, principalDisplayName
```

Expect differences between environments. Decide per difference which one is right; that is the
real work, and the reason to do this at all.

## 3. Match the display names

Applications are found by display name. Choose a convention with tokens, such as
`orders-api-#{environment}#`, and make the existing names fit it: rename them in the portal. A
rename keeps the application, its IDs and everything that refers to it. Do this before the first
run, or the script creates new applications next to the old ones.

If one environment has two applications with the same name, the run stops. Delete or rename the
spare first.

## 4. Write the definitions

Write one definition per application, with the roles and scopes as they exist. Keep the `value` of
every role and scope exactly as it is: the script matches existing ones by value and keeps their
IDs, so assignments and consent survive. Descriptions and display names can be tidied up; that
only updates them.

Leave out what you do not want managed yet. An absent `appRoles`, `scopes`,
`requiredResourceAccess`, `preAuthorizedApplications` or redirect URI platform is left alone.

Leave out `credential` too, at first. If an application already has a certificate under another
name, a `credential` block makes the script add a new one named `AppReg-<displayName>`, next to it.
That is fine, but it is a change to plan for: point the application at the new certificate, then
remove the old one.

```powershell
./Test-AppRegistrationConfig.ps1
```

## 5. Environment files, hands off

Start every environment file with management of people switched off:

```json
{
  "name": "prod",
  "tokens": { "environment": "prod" },
  "owners": ["orders-platform-owners"],
  "manageOwners": false,
  "manageRoleAssignments": false,
  "redirectUris": { "orders-web": ["https://orders.example.com/"] }
}
```

## 6. Plan until it is boring

```powershell
./Invoke-AppRegistrations.ps1 -Environment dev -WhatIf
```

Read every line. Each is either a difference you decided to fix in step 2, or a mistake in the
definitions. Adjust and plan again, until the plan shows only intended changes. Then apply, and
plan again: it should say *No changes*. Repeat per environment, production last.

## 7. Bring people under management

Write the role members you found in step 2, as you decided they should be, into `roleMembers`.
Prefer groups over individual users: then joining the group is enough, no pull request needed.

Set `"manageRoleAssignments": true` and plan. The plan now lists every assignment that would be
removed:

```text
  [plan] orders-api-prod: remove role 'Orders.Admin' from Alex Example
```

Each such line is someone losing access. Either it is intended, or they are missing from the file.
Only apply when every removal is intended. Do the same for owners with `"manageOwners": true`.

## 8. Make it the only way

- Run `Test-AppRegistrationConfig.ps1` in the pull request build.
- Apply from a pipeline ([Running in a pipeline](running-in-a-pipeline.md)), or agree who runs it
  locally, and when.
- Tell the people with portal access that changes there will be undone. Changes made by hand are
  now drift: the next run removes them.

## Your code

Nothing in your applications has to change, as long as the values of roles and scopes stay the
same. Two things to check:

- **The audience.** The script sets v2 access tokens. Their `aud` claim is the application ID (a
  GUID), not `api://<appId>`. An API that validates the audience must accept the application ID.
- **The roles.** With *assignment required* on, a user or application without a role no longer
  gets a token. That is the intent, but a developer testing against a shared environment needs a
  role too: put them, or their group, in the file.

Then make the code side as deliberate as the registrations:

- [Securing your API](securing-your-api.md): validate the token, turn roles and scopes into named
  policies, and make every endpoint name one.
- [Testing authorization](testing-authorization.md): prove it, with tokens you issue in the tests.
- [Calling other services](calling-other-services.md): managed identities, the on-behalf-of flow,
  and Application Insights without an instrumentation key.
- [Access management](access-management.md): from business role to group to app role, with reviews.

The [sample API](../samples/) shows all of it in one small project.
