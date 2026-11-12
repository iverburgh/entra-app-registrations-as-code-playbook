# Entra ID app registrations as code

Define the app registrations of your solution once, in JSON. Keep per environment only what
differs: who owns them, who has which role, which redirect URIs. A PowerShell script makes
Microsoft Entra ID match, in any environment, as often as you like. The second run changes nothing.

```text
app-registrations.json          environments/dev.json        environments/prod.json
  orders-api                      owners: orders-owners         owners: orders-owners-prod
    roles, scopes, certificate    Orders.Read: orders-testers   Orders.Read: orders-support
  orders-web                      orders-web: localhost:5173    orders-web: orders.example.com
    SPA, permissions                    │                             │
  orders-worker                         ▼                             ▼
    application permissions       orders-api-dev …              orders-api-prod …
```

## Why

App registrations made by hand drift apart: a role exists in test but not in production, someone
added an owner who left two years ago, a redirect URI points at a server that no longer exists.
Nobody can say who has access to what without clicking through the portal.

With the registrations in code:

- **Every environment is the same**, except where the environment file says otherwise.
- **Access is reviewed like code.** Adding someone to a role is a pull request.
- **Drift is undone.** A role assignment or owner added by hand is removed on the next run.
- **New environments are cheap.** Copy an environment file, run the script.
- **Consent is visible.** One command lists every permission that still needs admin consent.

## What it manages

| Per application                                   | Per environment                          |
| ------------------------------------------------- | ---------------------------------------- |
| Application and service principal                 | Owners (groups expanded to members)      |
| Identifier URI `api://<appId>`, v2 access tokens   | Role members: users, groups, services    |
| App roles and delegated scopes                    | Redirect URIs                            |
| Pre-authorized client applications                | Tokens such as `#{environment}#`         |
| Requested API permissions, by name                |                                          |
| Certificate or client secret, kept in Key Vault   |                                          |
| "Assignment required"                             |                                          |

It calls Microsoft Graph through the Azure CLI (`az rest`), so it runs wherever you are signed in
with `az login`: on your machine, or in a pipeline with a federated service connection.

## Quick start

Requirements: PowerShell 7.2 or later and the Azure CLI. Pester 5 to run the tests.

```powershell
cd app-registrations

# Offline: check the definitions and every environment file
./Test-AppRegistrationConfig.ps1

# Sign in, then see what would change in dev, without changing anything
az login --allow-no-subscriptions
./Invoke-AppRegistrations.ps1 -Environment dev -WhatIf

# Apply
./Invoke-AppRegistrations.ps1 -Environment dev

# Which permissions still need admin consent?
./Get-ConsentStatus.ps1 -Environment dev -OnlyMissing
```

Start with [Getting started](docs/getting-started.md).

## Documentation

| Document                                                  | Read it to                                                     |
| --------------------------------------------------------- | -------------------------------------------------------------- |
| [Getting started](docs/getting-started.md)                | Run the example against your own tenant                        |
| [How it works](docs/how-it-works.md)                      | Understand the three phases, idempotency and the dry run       |
| [Configuration](docs/configuration.md)                    | Look up every key of the definition and environment files      |
| [Roles and members](docs/roles-and-members.md)            | Assign users, groups and services, and know what drift does    |
| [Credentials](docs/credentials.md)                        | Use certificates and secrets in Key Vault, and renew them      |
| [Consent](docs/consent.md)                                | Find and grant the permissions that need an administrator      |
| [Running in a pipeline](docs/running-in-a-pipeline.md)    | Run it unattended, with least-privilege permissions            |
| [Applying it to your solution](docs/applying-to-your-solution.md) | Bring existing app registrations under management      |
| [Securing your API](docs/securing-your-api.md)            | Validate tokens and turn roles and scopes into policies        |
| [Testing authorization](docs/testing-authorization.md)    | Prove who may call what, with tokens issued in the tests       |
| [Calling other services](docs/calling-other-services.md)  | Use managed identities, on-behalf-of, Application Insights with Entra ID |
| [Access management](docs/access-management.md)            | Connect business roles, groups and app roles, and review them  |
| [Pitfalls](docs/pitfalls.md)                              | Avoid the mistakes that cost an afternoon                      |

## Sample API

[samples/](samples/) is a small ASP.NET Core API for the `orders-api` registration: token
validation, a policy per kind of access, the on-behalf-of flow, an explicitly chosen managed identity
and Application Insights with Entra ID. Its tests issue their own tokens and run in memory:

```powershell
dotnet test samples/Orders.slnx
```

Requires the .NET 10 SDK.

## Repository layout

```text
app-registrations/
  app-registrations.json        definitions, shared by all environments
  environments/*.json           one file per environment
  certificate-policy.json       Key Vault policy for new certificates
  schemas/                      JSON schemas, for validation and editor completion
  Invoke-AppRegistrations.ps1   apply one environment (-WhatIf to plan)
  Invoke-AllAppRegistrations.ps1  apply every environment, lowest first
  Test-AppRegistrationConfig.ps1  validate offline
  Get-ConsentStatus.ps1         requested versus granted permissions
  Compare-ConsentStatus.ps1     consent differences between two environments
  lib/                          the implementation; Graph.ps1 is the only part that talks to Azure
  tests/                        Pester tests against an in-memory fake directory
pipelines/
  app-registrations.yml         validate, plan, apply after approval
  templates/assert-app-registration.yml  preflight for a deployment pipeline
samples/
  src/Orders.Api/               the API: authentication, policies, identities, on-behalf-of
  tests/Orders.Api.Tests/       token validation, role matrix, endpoint convention, contract tests
tools/                          leak check and link check for this repository
```

## Related playbooks

From the same monorepo, each on its own:

- [Domain-Driven Design in .NET](https://github.com/iverburgh/ddd-dotnet-playbook) — bounded
  contexts, aggregates, domain events and the outbox in a working .NET solution.
- [Azure App Configuration](https://github.com/iverburgh/azure-app-configuration-playbook) —
  configuration as code, including the Key Vault references that hold the certificates created here.
- [Copilot on Azure DevOps](https://github.com/iverburgh/copilot-azure-devops-playbook) —
  instructions, skills and agents for a repository like this one.
- [Path filters on Azure DevOps](https://github.com/iverburgh/azure-devops-path-filter-playbook) —
  build and deploy only what a change touches.
- [Renovate on Azure DevOps](https://github.com/iverburgh/renovate-azure-devops-playbook) —
  automated dependency updates.

## License

[MIT](LICENSE)
