# Consent

Requesting a permission does not grant it. `requiredResourceAccess` is a wish list; someone with
enough rights has to agree, per tenant. That someone is often not on your team, so it helps to know
exactly what to ask for.

## Who grants what

| Permission                                          | Granted by                                         |
| --------------------------------------------------- | -------------------------------------------------- |
| Application permission (role) on an **own** API     | the script: it assigns the role                    |
| Delegated permission (scope) on an **own** API      | pre-authorizing the client in the API's definition |
| Application permission on **another** API, Graph    | an administrator, through admin consent            |
| Delegated permission on another API, Graph          | an administrator, or each user if the tenant allows |

The script does not grant permissions on APIs it does not define, on purpose: doing so needs
directory-wide rights, and asking for consent is the moment someone outside the team looks at what
your application wants.

## Status per permission

```powershell
./Get-ConsentStatus.ps1 -Environment test
```

```text
App                  Resource              Permission       Type         Status
---                  --------              ----------       ----         ------
orders-api-test      microsoft-graph       User.Read        Delegated    Granted
orders-web-test      microsoft-graph       User.Read        Delegated    Missing
orders-web-test      orders-api            access_as_user   Delegated    PreAuthorized
orders-worker-test   invoices-api-test     Invoices.Create  Application  Missing
orders-worker-test   orders-api            Orders.Process   Application  Granted

Ask an administrator to grant admin consent for:
  orders-web-test (<appId>)
    - User.Read (Delegated) on microsoft-graph
    https://login.microsoftonline.com/<tenant-id>/adminconsent?client_id=<appId>
```

| Status               | Meaning                                                                         |
| -------------------- | ------------------------------------------------------------------------------- |
| `Granted`            | application permission assigned, or delegated permission consented for all users |
| `PreAuthorized`      | delegated permission on an own API that pre-authorizes this client               |
| `Missing`            | requested, not granted: an administrator must consent                           |
| `AppNotFound`        | the application does not exist yet: run the script first                        |
| `ResourceNotFound`   | the requested API does not exist (yet) in this tenant                            |
| `PermissionNotFound` | the API exists, but does not offer this role or scope                            |

`-OnlyMissing` shows only what needs action. A delegated permission counts as granted only with an
admin consent for all users; consent that individual users gave themselves is not counted.

The admin consent URL grants everything the application requests in one go. The administrator sees
the full list before agreeing.

## Comparing environments

```powershell
./Compare-ConsentStatus.ps1 -Reference test -Difference prod
```

```text
AppKey         Resource                       Permission       Type         test      prod
------         --------                       ----------       ----         ----      ----
orders-worker  invoices-api-#{environment}#   Invoices.Create  Application  Granted   Missing
```

Rows are matched on the definition as written, not on names. `invoices-api-test` and
`invoices-api-prod` are the same line, because both come from `invoices-api-#{environment}#`.

Run this before promoting a release that adds a permission: a missing consent in production shows
up as an error at the first call, not at deployment.

## Reading what is granted

The status is read, never changed. The identity running it needs to read applications, service
principals, app role assignments and delegated permission grants: `Application.Read.All` and
`DelegatedPermissionGrant.Read.All`, or `Directory.Read.All`.
