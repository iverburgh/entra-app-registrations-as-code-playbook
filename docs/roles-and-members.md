# Roles and members

Who may do what is the part of an app registration that changes most, and matters most. Here it is
a list in a file, reviewed in a pull request, the same in every run.

## Where roles come from

Roles are defined once, per application, in `app-registrations.json`. Who has them is defined per
environment, under `roleMembers`:

```json
"roleMembers": {
  "Orders.Read": ["orders-support-readonly", "orders-operations"],
  "Orders.Admin": ["orders-operations"],
  "orders-web/Orders.Admin": ["orders-support-supervisors"],
  "Orders.Process": ["sp:id-orders-processor-prod"]
}
```

A plain role value applies to every application that defines that role. Here `orders-api` and
`orders-web` both define `Orders.Read` and `Orders.Admin`, so one list grants both. A key with an
application prefix adds members for that application only.

## Users, groups and service principals

| Name in the file                | Resolved as                                                    |
| ------------------------------- | -------------------------------------------------------------- |
| `user:alex@example.com`         | the user with that user principal name                         |
| `group:orders-operations`       | the group with that display name                               |
| `sp:id-orders-processor-prod`   | the service principal with that display name                   |
| `alex@example.com`              | a user, else a group, else a service principal                 |
| `orders-operations`             | a group, else a service principal, else a user                 |

Use a prefix when a group and a managed identity share a name, or simply to make the file easier to
read. Two objects of the same kind with the same name stop the run.

## What gets assigned

**A user** is assigned directly.

**A group** is assigned as itself. Its members get the role in their tokens, and joining or leaving
the group is enough to gain or lose it: no change to this repository needed. Assigning groups to
app roles requires Microsoft Entra ID P1 or P2. Only *direct* members of the assigned group get the
role; members of a nested group do not.

**A service principal** (a managed identity, another application) is assigned directly. Service
principals that are *members of a listed group* are assigned directly as well. App-only tokens do
not carry roles assigned through a group, so without this, putting a managed identity in the
"readers" group would silently do nothing. A role that does not allow applications skips those
service principals.

**An own application** that requests a role as an application permission:

```json
{ "key": "orders-worker", "requiredResourceAccess": [{ "resource": "orders-api", "roles": ["Orders.Process"] }] }
```

is assigned that role by the script. Within your own solution, requesting is granting: the request
is reviewed in the same pull request as the definition.

## Allowed member types are enforced

A role allows `User`, `Application`, or both. Listing a user or group in a role that only allows
applications, or a service principal in a role that only allows users, stops the run with a message
naming the role and the member. Entra ID would accept some of those assignments and then not put
the role in any token.

## The file is the source of truth

Per role, the desired members are the listed ones plus the own applications requesting the role.
Every other assignment on that role is removed, including ones made in the portal:

```text
  [change] orders-api-prod: remove role 'Orders.Admin' from Alex Example
```

That is the point: access granted by hand, "just for this incident", does not linger. If you need
an exception, put it in the file, with the reason in the commit message.

Two ways to opt out:

- `"manageRoleAssignments": false` in an environment file leaves all assignments in that
  environment alone. Useful while migrating, or in a sandbox.
- A role that is not defined in `app-registrations.json` is not touched.

## Owners

`owners` lists who owns every application and service principal in the environment:

```json
"owners": ["orders-platform-owners"]
```

Owners must be users or service principals, so groups are expanded to their members, nested groups
included. Owners not in the list are removed. The identity running the script is always kept as
owner, so a pipeline never locks itself out of the applications it manages.

Set `"manageOwners": false` when the running identity may not change owners. See
[Running in a pipeline](running-in-a-pipeline.md#2-microsoft-graph-permissions).

## Names that cannot be found

A name that does not resolve stops the run. Otherwise a typo, a deleted group or a renamed
managed identity would look like "nobody should have this role", and the run would remove the
access of everyone else on it.

```text
Principal 'orders-admins-typo' was not found as a user, group or service principal. A missing name
would silently remove access, so the run stops. Use -AllowUnresolvedPrincipals to skip it instead.
```

`-AllowUnresolvedPrincipals` skips such names with a warning. Use it for a first run in a new
environment where not every group exists yet, not as a default.

## "Assignment required"

Every service principal is set to *assignment required* unless the definition says
`"assignmentRequired": false`. Then only users and applications with a role, directly or through a
group, get a token for the application. Without it, any user in the tenant can sign in to it, and
the roles are only as good as the checks in your code.
