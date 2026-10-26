# Running in a pipeline

The script runs the same on a laptop as in a pipeline: it uses whatever the Azure CLI is signed in
as. In a pipeline that is the service principal of a service connection, and that service principal
needs Microsoft Graph permissions. Getting those is often the hard part, organisationally, so this
page is mostly about them.

If your pipeline cannot get these permissions, run the script locally, as someone with the
*Cloud Application Administrator* role. Everything else in this repository works the same. Keep the
validation in the pull request build either way.

## The pipeline

[pipelines/app-registrations.yml](../pipelines/app-registrations.yml) has three stages:

| Stage    | Runs                                                            | Needs Azure |
| -------- | --------------------------------------------------------------- | ----------- |
| Validate | the Pester tests and `Test-AppRegistrationConfig.ps1`           | no          |
| Plan     | `Invoke-AppRegistrations.ps1 -WhatIf`                           | read        |
| Apply    | `Invoke-AppRegistrations.ps1`, in a deployment job              | write       |

Apply runs on an Azure DevOps *environment* named `app-registrations-<environment>`. Add an
approval check to it: the approver reads the plan of the previous stage, then approves. Add a
*branch control* check too, so only the main branch can apply.

Pull request runs stop after Plan, so a reviewer sees the effect of a change before merging it.

## Setting it up

### 1. A service connection per environment

Create an *Azure Resource Manager* service connection with *workload identity federation*, named
`sc-app-registrations-<environment>`. No secret to rotate, nothing to leak. Point it at the
subscription that holds the Key Vaults; the Key Vault roles below are all the Azure RBAC it needs.

Use these service connections for this pipeline only. Restrict them to it under *Pipeline
permissions*: whoever can use the connection can do what its permissions allow.

### 2. Microsoft Graph permissions

Grant the service connection's service principal these Microsoft Graph *application* permissions,
with admin consent:

| Permission                         | Why                                                                     |
| ---------------------------------- | ----------------------------------------------------------------------- |
| `Application.ReadWrite.OwnedBy`    | create applications and service principals, and manage the ones it owns |
| `Application.Read.All`             | find other APIs by name, read the roles and scopes they offer           |
| `AppRoleAssignment.ReadWrite.All`  | assign and remove app roles                                             |
| `User.ReadBasic.All`               | find users by user principal name                                       |
| `GroupMember.Read.All`             | find groups by name, and their members                                  |
| `DelegatedPermissionGrant.Read.All` | read admin consent, for `Get-ConsentStatus.ps1` only                   |

Changing owners needs more: `Application.ReadWrite.OwnedBy` cannot add another owner. Either grant
`Application.ReadWrite.All`, or keep owner changes out of the pipeline:

- set `"manageOwners": false` in the environment files the pipeline applies, or
- leave it on, and apply owner changes with a local run. The script only writes owners when they
  differ, so the pipeline runs fine as long as the owner lists stay the same.

An administrator (*Privileged Role Administrator* or *Global Administrator*) grants these, in the
portal under the service principal's *API permissions*, or with the Azure CLI:

```powershell
$graph = az ad sp show --id 00000003-0000-0000-c000-000000000000 | ConvertFrom-Json
$sp = az ad sp show --id '<application ID of the service connection>' | ConvertFrom-Json
$permissions = 'Application.ReadWrite.OwnedBy', 'Application.Read.All', 'AppRoleAssignment.ReadWrite.All',
               'User.ReadBasic.All', 'GroupMember.Read.All', 'DelegatedPermissionGrant.Read.All'
foreach ($permission in $permissions) {
    $role = $graph.appRoles | Where-Object value -EQ $permission
    $body = @{ principalId = $sp.id; resourceId = $graph.id; appRoleId = $role.id } | ConvertTo-Json -Compress
    $file = New-TemporaryFile
    Set-Content -LiteralPath $file -Value $body
    az rest --method POST --uri "https://graph.microsoft.com/v1.0/servicePrincipals/$($graph.id)/appRoleAssignedTo" --headers 'Content-Type=application/json' --body "@$file"
    Remove-Item $file
}
```

### 3. Ownership of existing applications

`Application.ReadWrite.OwnedBy` only reaches applications the service principal owns. Applications
the pipeline creates, it owns automatically. Applications that already exist need it added as owner
once. The simplest way: list the service principal in `owners`, and run the script locally as an
administrator:

```json
"owners": ["orders-platform-owners", "sp:sc-app-registrations-prod"]
```

Use the display name of the service connection's service principal. From then on the pipeline
manages everything, and keeps itself as owner.

### 4. Key Vault roles

| Credential type in the definitions | Role on the vault              |
| ---------------------------------- | ------------------------------ |
| `certificate`                      | Key Vault Certificates Officer |
| `secret`                           | Key Vault Secrets Officer      |

## These permissions are powerful

Be clear-eyed about what you hand the pipeline:

- `AppRoleAssignment.ReadWrite.All` can grant *any* application permission to *any* service
  principal, its own included, Microsoft Graph's most powerful ones too. In effect it can make
  itself an administrator.
- `Application.ReadWrite.All`, if you grant it, can add a credential to any application in the
  tenant, and act as it.

So treat the service connection as you would an administrator account: one pipeline, the main
branch only, an approval before Apply, required reviewers on the `app-registrations/` folder. If
your organisation will not accept that, run locally. That is a legitimate choice, not a failure:
the configuration, validation and review still give you most of the value.

## A preflight in deployment pipelines

When app registrations are applied separately from deployments, a deployment can run before its
app registration exists. [pipelines/templates/assert-app-registration.yml](../pipelines/templates/assert-app-registration.yml)
checks that the application and, optionally, its certificate exist. If not, a manual validation
asks someone to apply the app registrations first and then resume, instead of the deployment
failing halfway.

```yaml
jobs:
- template: templates/assert-app-registration.yml
  parameters:
    name: ordersApi
    serviceConnection: sc-orders-dev
    displayName: orders-api-dev
    keyVault: kv-orders-dev
    certificateName: AppReg-orders-api-dev
- deployment: Deploy
  dependsOn: [ordersApi_check, ordersApi_confirm]
  condition: and(succeeded('ordersApi_check'), in(dependencies.ordersApi_confirm.result, 'Succeeded', 'Skipped'))
  # ...
```

The deployment's own service connection only needs to read: `Application.Read.All`, and
*Key Vault Certificates User* on the vault.

## All environments at once

Locally, `Invoke-AllAppRegistrations.ps1` applies every environment in `order`, lowest first, and
stops at the first failure, so a mistake shows in a test environment before it reaches production:

```powershell
./Invoke-AllAppRegistrations.ps1 -WhatIf
./Invoke-AllAppRegistrations.ps1 -Environment dev, test
```

In a pipeline, prefer one run per environment, each with its own service connection and approval.
