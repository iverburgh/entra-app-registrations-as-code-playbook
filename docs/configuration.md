# Configuration

Two kinds of files: `app-registrations.json` defines the applications, once; one file per
environment in `environments/` says what differs. Both have a JSON schema in `schemas/`; reference
it with `$schema` and your editor completes and checks the keys.

## app-registrations.json

```json
{
  "$schema": "./schemas/app-registrations.schema.json",
  "appRegistrations": [
    { "key": "orders-api", "displayName": "orders-api-#{environment}#", "...": "..." }
  ]
}
```

### Application

| Key                         | Required | Meaning                                                                                   |
| --------------------------- | -------- | ----------------------------------------------------------------------------------------- |
| `key`                       | yes      | Stable name used inside the configuration: lower case, digits, hyphens. Never shown in Entra ID. |
| `displayName`               | yes      | Name in Entra ID, usually with tokens. **It identifies the application**: see [Pitfalls](pitfalls.md#renaming-creates-a-new-application). |
| `appRoles`                  | no       | Roles of this application. Absent: left alone. `[]`: none.                                 |
| `scopes`                    | no       | Delegated permissions this API offers. Absent: left alone.                                 |
| `preAuthorizedApplications` | no       | Clients that may use the scopes without a consent prompt.                                  |
| `requiredResourceAccess`    | no       | Permissions this application requests on other APIs.                                       |
| `redirectUris`              | no       | Per platform, the name of a redirect URI list in the environment file.                     |
| `credential`                | no       | A certificate or client secret, kept in Key Vault. See [Credentials](credentials.md).      |
| `assignmentRequired`        | no       | Default `true`: only users and applications with a role get a token.                       |

### Role

```json
{
  "value": "Orders.Read",
  "displayName": "Order reader",
  "description": "Read orders and their history.",
  "allowedMemberTypes": ["User", "Application"]
}
```

`value` is what ends up in the `roles` claim of the token. `allowedMemberTypes` says who can have
the role: `User` (users and groups), `Application` (service principals), or both. `isEnabled`
defaults to `true`.

### Scope

```json
{
  "value": "access_as_user",
  "adminConsentDisplayName": "Access the orders API as the signed-in user",
  "adminConsentDescription": "Lets the application call the orders API on behalf of the signed-in user."
}
```

Optional: `type` (`User`, the default, lets users consent themselves; `Admin` needs an
administrator), `userConsentDisplayName`, `userConsentDescription`, `isEnabled`.

### Pre-authorized application

```json
{ "application": "orders-web", "scopes": ["access_as_user"] }
```

`application` is the key of an own application, a well-known name, or an application ID. The
well-known names are `azure-cli` and `azure-powershell`; pre-authorizing `azure-cli` lets
developers get a token for your API with `az account get-access-token --resource api://<appId>`.

### Requested permission

```json
{ "resource": "orders-api", "roles": ["Orders.Process"] }
{ "resource": "microsoft-graph", "scopes": ["User.Read"] }
{ "resource": "invoices-api-#{environment}#", "roles": ["Invoices.Create"] }
```

`scopes` are delegated permissions (on behalf of a user), `roles` are application permissions
(as the application itself). `resource` is, in this order:

1. the key of an own application;
2. a well-known name: `microsoft-graph`, `azure-cli`, `azure-powershell`;
3. an application ID;
4. the display name of a service principal in the tenant, such as another team's API.

Roles requested on an own API are assigned by the script. Everything else needs admin consent:
see [Consent](consent.md).

### Redirect URIs

```json
"redirectUris": { "spa": "orders-web" }
```

The platform (`spa`, `web` or `publicClient`) points at a list in the environment file. URIs differ
per environment, so they live there.

## environments/&lt;name&gt;.json

```json
{
  "$schema": "../schemas/environment.schema.json",
  "name": "test",
  "order": 2,
  "tokens": { "environment": "test", "instance": "" },
  "owners": ["orders-platform-owners"],
  "roleMembers": {
    "Orders.Read": ["orders-testers", "user:tester@example.com"],
    "orders-web/Orders.Admin": ["orders-support-supervisors"],
    "Orders.Process": ["sp:id-orders-processor-test"]
  },
  "redirectUris": {
    "orders-web": ["https://orders-test.example.com/"]
  }
}
```

| Key                     | Default     | Meaning                                                                                       |
| ----------------------- | ----------- | --------------------------------------------------------------------------------------------- |
| `name`                  | file name   | Name in messages and in the consent comparison.                                               |
| `order`                 | -           | Order for `Invoke-AllAppRegistrations.ps1`: lowest first, so production comes last.          |
| `tokens`                | `{}`        | Values for `#{name}#` in the definitions. A token without a value stops the run.              |
| `owners`                | `[]`        | Users, groups and service principals that own every application. Groups are expanded.         |
| `manageOwners`          | `true`      | `false` leaves owners alone, for instance when the running identity may not change them.      |
| `roleMembers`           | `{}`        | Members per role. See below.                                                                  |
| `manageRoleAssignments` | `true`      | `false` leaves role assignments alone.                                                        |
| `redirectUris`          | `{}`        | Named lists of redirect URIs, referred to by the definitions.                                  |

### Role members

A key is a role value, or `<application key>/<role value>`:

- `"Orders.Read"` applies to every application that defines a role `Orders.Read`.
- `"orders-web/Orders.Admin"` applies only to `orders-web`, in addition to the members of
  `"Orders.Admin"`.

A value is a list of names. Prefix a name to say what it is: `user:`, `group:` or `sp:`. Without a
prefix, a name with `@` is tried as a user first, then as a group, then as a service principal; a
name without `@` as a group, a service principal, then a user. Two objects of the same kind with
the same name stop the run. See [Roles and members](roles-and-members.md).

## Tokens

Any `#{name}#` in the definitions is replaced by `tokens.name` from the environment file. Values
are inserted as JSON string content, so quotes and backslashes are safe.

A token with an empty value is useful for optional parts. The example uses `#{instance}#` for a
second test environment in the same tenant:

| Environment file | `environment` | `instance` | `orders-api#{instance}#-#{environment}#` |
| ---------------- | ------------- | ---------- | ---------------------------------------- |
| `test.json`      | `test`        | `""`       | `orders-api-test`                         |
| `test-2.json`    | `test`        | `"2"`      | `orders-api2-test`                        |

## certificate-policy.json

The Key Vault certificate policy for new certificates: self-signed, RSA 2048, valid for six months,
with an e-mail to the vault's certificate contacts 30 days before expiry. See
[Credentials](credentials.md).

## Validation

```powershell
./Test-AppRegistrationConfig.ps1
```

Checks the schemas, then the references between files: that every requested own role and scope
exists, that roles requested by applications allow applications, that pre-authorized clients and
scopes exist, that every role member key matches a role, that every redirect URI list exists, that
keys and display names are unique. Run it in every pull request build; it needs no Azure access.
