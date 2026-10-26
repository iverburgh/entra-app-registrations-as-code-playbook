---
applyTo: 'app-registrations/**'
---

# App registrations as code

- `app-registrations.json` defines each application once; `environments/<name>.json` holds only what
  differs per environment: tokens, owners, role members, redirect URIs.
- `displayName` identifies an application. Never change it without renaming the application in
  Entra ID first; otherwise the next run creates a new application.
- Roles and scopes are matched by `value`. Never change a value to rename a role: add the new one,
  migrate, then remove the old one.
- An absent key (`appRoles`, `scopes`, `requiredResourceAccess`, `preAuthorizedApplications`) is
  left alone; an empty list removes everything.
- Role members: prefer groups; prefix names with `user:`, `group:` or `sp:` when ambiguous. A role
  member must match the role's `allowedMemberTypes`.
- Requesting a role on an own API grants it. Permissions on other APIs need admin consent; check
  with `Get-ConsentStatus.ps1`.
- After every change run `./Test-AppRegistrationConfig.ps1` and
  `Invoke-Pester ./app-registrations/tests`. Never call Microsoft Graph or the Azure CLI directly from
  `lib/AppRegistrations.ps1`; go through `Invoke-Graph` and `Invoke-AzCli` in `lib/Graph.ps1`.
- Never print or log a secret value.
