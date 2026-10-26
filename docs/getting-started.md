# Getting started

This walks you through running the example against a tenant of your own. Use a test tenant, or a
tenant where creating a few app registrations named `orders-*-dev` bothers nobody.

## 1. What you need

- **PowerShell 7.2 or later** (`pwsh`) and the **Azure CLI**.
- **A role in Entra ID** that can create app registrations and assign users to applications:
  *Cloud Application Administrator* or *Application Administrator*.
- **A Key Vault** for the credentials, on which you have the *Key Vault Certificates Officer* and
  *Key Vault Secrets Officer* roles. Skip this by removing the `credential` blocks for now.
- **Pester 5**, if you want to run the tests: `Install-Module Pester -MinimumVersion 5.5.0`.

## 2. Validate offline

```powershell
cd app-registrations
./Test-AppRegistrationConfig.ps1
```

This checks the definitions and every environment file against the JSON schemas, and checks what a
schema cannot: references to roles, scopes and applications that do not exist, role members for
roles nobody defines, redirect URI lists an environment lacks. It needs no Azure access, so it is
also what a pull request build runs.

## 3. Make the example fit your tenant

The example environment files name groups and service principals that do not exist in your tenant.
Edit `environments/dev.json`:

```json
{
  "name": "dev",
  "tokens": { "environment": "dev", "instance": "" },
  "owners": ["you@yourtenant.example"],
  "roleMembers": {
    "Orders.Read": ["you@yourtenant.example"],
    "Orders.Process": []
  },
  "redirectUris": {
    "orders-web": ["http://localhost:5173/"]
  }
}
```

Names are resolved at run time: a user by user principal name, a group or service principal by
display name. See [Roles and members](roles-and-members.md).

In `app-registrations.json`, either point `keyVault` at your vault, or remove the `credential`
blocks. The `orders-worker` application requests a role on an API called `invoices-api-dev`;
remove that entry, or the run stops because the API does not exist.

## 4. Plan

```powershell
az login --allow-no-subscriptions
./Invoke-AppRegistrations.ps1 -Environment dev -WhatIf
```

`--allow-no-subscriptions` lets you sign in to a tenant without an Azure subscription. The plan
lists every change, and makes none:

```text
Planning app registrations for 'dev' in tenant <tenant-id> as you@yourtenant.example
orders-api-dev (orders-api)
  [plan] orders-api-dev: create application
  [plan] orders-api-dev: set identifier URI api://new:orders-api
  [plan] orders-api-dev: roles: add Orders.Read, Orders.Admin, Orders.Process
  ...
```

Applications that do not exist yet get placeholder IDs such as `new:orders-api` in the plan.

## 5. Apply

```powershell
./Invoke-AppRegistrations.ps1 -Environment dev
```

Run it again: it reports *No changes*. That is the property everything else builds on. See
[How it works](how-it-works.md).

## 6. Check consent

```powershell
./Get-ConsentStatus.ps1 -Environment dev
```

The `User.Read` permission on Microsoft Graph shows as *Missing*: requesting a permission does not
grant it. The script prints the admin consent URL to send to an administrator. See
[Consent](consent.md).

## 7. Clean up

The script never deletes an application. Delete the `orders-*-dev` registrations in the portal, or:

```powershell
'orders-api-dev', 'orders-web-dev', 'orders-worker-dev', 'orders-integration-tests-dev' | ForEach-Object {
    $id = az ad app list --display-name $_ --query '[0].id' --output tsv
    if ($id) { az ad app delete --id $id }
}
```

## Next

- Replace the example with your own applications: [Configuration](configuration.md).
- Bring existing registrations under management: [Applying it to your solution](applying-to-your-solution.md).
- Run it from a pipeline: [Running in a pipeline](running-in-a-pipeline.md).
