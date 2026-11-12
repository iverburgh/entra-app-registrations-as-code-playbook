# Credentials

An application that calls another API as itself needs a credential. The script creates one, keeps
it in Key Vault, and never prints it.

Prefer no credential at all: an application running in Azure can use a managed identity, and a
pipeline a federated service connection. Use a credential here for what cannot: an application
outside Azure, a test runner, an API that calls another API on behalf of a user.

## Certificate

```json
"credential": {
  "type": "certificate",
  "keyVault": "kv-orders-#{environment}#",
  "tags": { "owner": "orders-team", "purpose": "Client credential of the orders worker" }
}
```

The certificate is named `AppReg-<displayName>` (characters Key Vault does not allow become
hyphens). On a run:

1. If the vault has no such certificate, it is created with `certificate-policy.json`:
   self-signed, RSA 2048, six months, clientAuth usage. Key Vault creates the private key and never
   lets it out.
2. If it exists, its tags are made to match. Tags added by others are kept.
3. If the application has no credential with that name, the public key is added with
   `az ad app credential reset --append`. `--append` matters: without it, the CLI replaces every
   other credential of the application.

The application reads the certificate from Key Vault at run time with its own identity. It needs
the *Key Vault Secrets User* role: the private key of a Key Vault certificate is read through its
secret.

## Client secret

```json
"credential": {
  "type": "secret",
  "name": "pipeline",
  "keyVault": "kv-orders-#{environment}#",
  "validityInMonths": 6
}
```

If the application has no client secret with that `name`, the script adds one (default validity
12 months) and stores it straight in Key Vault as `AppReg-<displayName>-<name>`, with the same
expiry date. The value passes through a temporary file, never through the command line or the
output.

If storing it fails, the secret is removed from the application again: a secret nobody can read
is useless, and would stop the next run from creating a new one.

A secret's value cannot be read back from Entra ID. If the application has the secret but the vault
copy is gone, the run warns. Delete the client secret on the application and run again to get a
new one.

Prefer a certificate: a secret is a password that can be copied, a certificate's private key stays
in Key Vault.

## Renewal

The script creates credentials; it does not rotate them. Six months is short on purpose: renewal
must be routine, and a forgotten credential is not valid forever.

The pattern that works, for a certificate:

```mermaid
sequenceDiagram
    participant J as Renewal job
    participant KV as Key Vault
    participant E as Entra ID
    participant A as Application
    J->>KV: create a new version of AppReg-<name>
    J->>E: add its public key (--append)
    A->>KV: read the latest version
    Note over A: uses the new certificate
    J->>E: remove the old key credential
```

1. **Before expiry**, create a new version of the certificate in Key Vault. Key Vault's policy
   can do this itself (`AutoRenew` at a percentage of the lifetime) or e-mail you to do it
   (`EmailContacts`, the default here).
2. **Add the new public key** to the application, keeping the old one:

   ```powershell
   az ad app credential reset --id <appId> --keyvault <vault> --cert AppReg-<displayName> --append --display-name AppReg-<displayName>
   ```

3. **Let the application pick it up.** It should always read the *latest* version from Key Vault,
   so a restart, or a periodic reload, is enough.
4. **Remove the old key credential** once nothing uses it:

   ```powershell
   az ad app credential list --id <appId> --cert --query "[].{keyId:keyId, end:endDateTime}"
   az ad app credential delete --id <appId> --key-id <old keyId> --cert
   ```

Steps 2 to 4 can run in a scheduled job, or in the application itself. A separate job needs to be an
owner of the application, with `Application.ReadWrite.OwnedBy`. An application that renews its *own*
certificate needs no Graph permission at all; see the next section.

For a client secret: add a new secret with a new name, store it, move consumers over, delete the
old one.

## The application renews its own certificate

Microsoft Graph lets an application add and remove key credentials on itself, without any
permission, as long as it proves it holds a current private key. A background service in the
application can then do the whole renewal, and no pipeline or administrator account needs rights on
the app registration.

```mermaid
sequenceDiagram
    participant S as Renewal service
    participant KV as Key Vault
    participant E as Entra ID (Graph)
    S->>KV: read the current certificate, check its age
    S->>KV: create a new version: certificate signing request (pending)
    S->>S: sign a proof token with the current certificate
    S->>E: addKey (new public key + proof)
    S->>E: wait, then read the application: is the new key there?
    S->>KV: merge the signed certificate into the pending version
    S->>E: removeKey for expired keys (+ proof)
```

1. **Decide whether to renew.** Read the current certificate from Key Vault. Renew when it has used
   up a fixed part of its lifetime, two thirds for example. Leave enough margin for a few failed
   attempts before it expires.
2. **Create a pending version** in Key Vault, with an issuer of `Unknown`. Key Vault generates a new
   key pair and returns a certificate signing request (CSR). The private key never leaves Key Vault;
   the current version stays the active one.
3. **Build a proof of possession**: a short JWT signed with the *current* certificate's private key,
   with:

   | Claim | Value                                                          |
   | ----- | -------------------------------------------------------------- |
   | `aud` | `00000002-0000-0000-c000-000000000000`                         |
   | `iss` | the application's object ID                                    |
   | `nbf` | now                                                            |
   | `exp` | `nbf` plus at most ten minutes                                 |

4. **Add the new key** with `POST /applications/{id}/addKey`: the new public key, and the proof.
   Authenticate to Graph as the application itself, with the current certificate.
5. **Wait, and verify.** Entra ID replicates the change; read the application back until the new key
   is listed. Two instances calling `addKey` at the same moment can overwrite each other's key, so
   do not trust the response alone.
6. **Merge** the signed certificate into the pending version in Key Vault. It becomes the latest
   version, and the application uses it from the next time it reads the certificate.
7. **Remove old keys** with `POST /applications/{id}/removeKey`, again with a proof. Only expired
   keys, or keys older than the one now in use. Never the key you authenticated with in this run.

Things to get right:

- **Several instances.** Every instance runs the service. Before renewing, re-read the certificate:
  if another instance renewed it a minute ago, stop. Add a random delay to the schedule, so instances
  do not all start at the same second.
- **Who renews.** Tag the certificate in Key Vault (`renewedBy: application`) so that nobody adds a
  renewal job or a Key Vault auto-renew policy as well. Two mechanisms renewing the same certificate
  fight each other.
- **Too late is too late.** `addKey` needs a *valid* current certificate to sign the proof. Once all
  certificates have expired, the application cannot recover on its own: someone with rights on the
  app registration adds a new key, as in the renewal steps above. Alert well before that, on the
  certificate's expiry date in Key Vault.
- **Roles on the vault.** The application needs *Key Vault Certificates Officer* on its vault, not
  just *Secrets User*: it creates certificate versions.

## Key Vault roles for the script

| Credential  | Role on the vault                                   |
| ----------- | --------------------------------------------------- |
| certificate | Key Vault Certificates Officer                      |
| secret      | Key Vault Secrets Officer                           |

With access policies instead of Azure RBAC: certificates *get, create, update*; secrets *get, set*.
