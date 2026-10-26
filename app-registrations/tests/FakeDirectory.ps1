<#
.SYNOPSIS
    An in-memory Entra ID, Key Vault and Azure CLI account for the tests. Mock Invoke-Graph and
    Invoke-AzCli with Invoke-FakeGraph and Invoke-FakeAzCli.

.DESCRIPTION
    Implements the Graph calls the scripts make, and the rules that matter:
      - an enabled app role or scope cannot be changed or removed;
      - a scope that is pre-authorized cannot be removed;
      - a role can only be assigned once to the same principal, and only if it exists;
      - a service principal shows the roles and scopes of its application.
    Every write is recorded in $global:Fake.Writes, so tests can assert that a run changed nothing.
#>

function New-FakeDirectory {
    $global:Fake = [pscustomobject]@{
        Applications      = [ordered]@{}
        ServicePrincipals = [ordered]@{}
        Users             = @{}
        Groups            = @{}
        Owners            = @{}
        Assignments       = [Collections.Generic.List[object]]::new()
        Grants            = [Collections.Generic.List[object]]::new()
        Certificates      = @{}
        Secrets           = @{}
        Writes            = [Collections.Generic.List[string]]::new()
        Me                = $null
        Account           = $null
    }
    $me = Add-FakeUser -UserPrincipalName 'admin@example.com' -DisplayName 'Admin'
    $global:Fake.Me = $me
    $global:Fake.Account = @{ tenantId = 'contoso-tenant'; user = @{ name = 'admin@example.com'; type = 'user' } }
}

function New-FakeId { (New-Guid).Guid }

function Copy-FakeObject($Object) {
    if ($null -eq $Object) { return $null }
    ConvertTo-Json -InputObject $Object -Depth 30 | ConvertFrom-Json -Depth 30
}

function Get-FakeProperty($Object, [string] $Name, $Default = $null) {
    <# Reads an optional property; StrictMode throws on a missing one. #>
    if ($null -ne $Object -and $Object.PSObject.Properties[$Name]) { $Object.$Name } else { $Default }
}

function Add-FakeUser([string] $UserPrincipalName, [string] $DisplayName) {
    $id = New-FakeId
    $global:Fake.Users[$id] = [pscustomobject]@{ id = $id; userPrincipalName = $UserPrincipalName; displayName = $DisplayName ?? $UserPrincipalName }
    $id
}

function Add-FakeGroup([string] $DisplayName, [string[]] $MemberIds = @()) {
    $id = New-FakeId
    $global:Fake.Groups[$id] = [pscustomobject]@{ id = $id; displayName = $DisplayName; members = [Collections.Generic.List[string]]::new([string[]]@($MemberIds)) }
    $id
}

function Add-FakeServicePrincipal {
    <# A service principal without an application in this tenant: a managed identity, Microsoft Graph, another team's API. #>
    param([string] $DisplayName, [string] $AppId = (New-FakeId), [object[]] $AppRoles = @(), [object[]] $Scopes = @())
    $id = New-FakeId
    $global:Fake.ServicePrincipals[$id] = [pscustomobject]@{
        id                        = $id
        appId                     = $AppId
        displayName               = $DisplayName
        appRoleAssignmentRequired = $false
        appRoles                  = @($AppRoles | ForEach-Object { [pscustomobject]@{ id = $_['id'] ?? (New-FakeId); value = $_.value; displayName = $_.value; description = $_.value; allowedMemberTypes = @($_['allowedMemberTypes'] ?? @('Application')); isEnabled = $true } })
        oauth2PermissionScopes    = @($Scopes | ForEach-Object { [pscustomobject]@{ id = $_['id'] ?? (New-FakeId); value = $_.value; type = 'User'; isEnabled = $true } })
    }
    $id
}

function Get-FakeServicePrincipal([string] $Id) {
    $sp = $global:Fake.ServicePrincipals[$Id]
    if (-not $sp) { throw "Fake: service principal $Id not found (404)" }
    $copy = Copy-FakeObject $sp
    $application = $global:Fake.Applications.Values | Where-Object appId -EQ $sp.appId | Select-Object -First 1
    if ($application) {
        $copy.appRoles = @(Copy-FakeObject @($application.appRoles))
        $copy.oauth2PermissionScopes = @(Copy-FakeObject @($application.api.oauth2PermissionScopes))
        $copy.displayName = $application.displayName
    }
    $copy
}

function Get-FakeDisplayName([string] $Id) {
    if ($global:Fake.Users.ContainsKey($Id)) { return $global:Fake.Users[$Id].displayName }
    if ($global:Fake.Groups.ContainsKey($Id)) { return $global:Fake.Groups[$Id].displayName }
    if ($global:Fake.ServicePrincipals.Contains($Id)) { return (Get-FakeServicePrincipal $Id).displayName }
    throw "Fake: principal $Id does not exist"
}

function Get-FakeType([string] $Id) {
    if ($global:Fake.Users.ContainsKey($Id)) { return 'User' }
    if ($global:Fake.Groups.ContainsKey($Id)) { return 'Group' }
    'ServicePrincipal'
}

function Test-FakeFilter($Object, [string] $Filter) {
    foreach ($condition in ($Filter -split ' and ')) {
        if ($condition -notmatch "^(\w+) eq '(.*)'$") { throw "Fake: unsupported filter '$Filter'" }
        $value = $Matches[2].Replace("''", "'")
        if ("$($Object.($Matches[1]))" -ne $value) { return $false }
    }
    $true
}

function Assert-FakeEntitlementChange([object[]] $Existing, [object[]] $New, [string] $Kind, [string[]] $Properties) {
    foreach ($old in @($Existing | Where-Object isEnabled)) {
        $match = $New | Where-Object { $_.id -eq $old.id } | Select-Object -First 1
        if (-not $match) { throw "CannotDeleteOrUpdateEnabledEntitlement: $Kind '$($old.value)' must be disabled before it is removed." }
        foreach ($p in $Properties) {
            $a = $old.$p; $b = $match.$p
            if ($a -is [array] -or $b -is [array]) { $a = (@($a) | Sort-Object) -join ','; $b = (@($b) | Sort-Object) -join ',' }
            if ("$a" -ne "$b") { throw "CannotDeleteOrUpdateEnabledEntitlement: $Kind '$($old.value)' must be disabled before '$p' changes." }
        }
    }
}

function Invoke-FakeGraph {
    param([string] $Method = 'GET', [string] $Uri, $Body, [switch] $All, [switch] $AllowNotFound)
    if (-not $Method) { $Method = 'GET' }

    $path, $query = ($Uri -replace '^https://graph\.microsoft\.com/(v1\.0|beta)', '') -split '\?', 2
    $filter = if ($query -match '\$filter=([^&]+)') { [uri]::UnescapeDataString($Matches[1]) } else { $null }
    $body = if ($null -ne $Body) { Copy-FakeObject $Body } else { $null }
    if ($Method -ne 'GET') { $global:Fake.Writes.Add("$Method $path") }

    $result = switch -Regex ("$Method $path") {
        '^GET /applications$' { @{ value = @($global:Fake.Applications.Values | Where-Object { -not $filter -or (Test-FakeFilter $_ $filter) } | ForEach-Object { Copy-FakeObject $_ }) } }
        '^POST /applications$' {
            $id = New-FakeId
            $global:Fake.Applications[$id] = [pscustomobject]@{
                id                     = $id
                appId                  = New-FakeId
                displayName            = $body.displayName
                signInAudience         = Get-FakeProperty $body 'signInAudience' 'AzureADMyOrg'
                identifierUris         = @()
                appRoles               = @()
                api                    = [pscustomobject]@{ requestedAccessTokenVersion = Get-FakeProperty (Get-FakeProperty $body 'api') 'requestedAccessTokenVersion'; oauth2PermissionScopes = @(); preAuthorizedApplications = @(); knownClientApplications = @() }
                spa                    = [pscustomobject]@{ redirectUris = @() }
                web                    = [pscustomobject]@{ redirectUris = @(); redirectUriSettings = @(); implicitGrantSettings = [pscustomobject]@{ enableIdTokenIssuance = $false; enableAccessTokenIssuance = $false } }
                publicClient           = [pscustomobject]@{ redirectUris = @() }
                keyCredentials         = @()
                passwordCredentials    = @()
                requiredResourceAccess = @()
            }
            Copy-FakeObject $global:Fake.Applications[$id]
        }
        '^GET /applications/([^/]+)$' { Copy-FakeObject $global:Fake.Applications[$Matches[1]] }
        '^PATCH /applications/([^/]+)$' {
            $application = $global:Fake.Applications[$Matches[1]]
            foreach ($property in $body.PSObject.Properties) {
                if ($property.Name -eq 'appRoles') {
                    Assert-FakeEntitlementChange @($application.appRoles) @($property.Value) 'role' 'value', 'displayName', 'description', 'allowedMemberTypes'
                }
                if ($property.Name -eq 'api') {
                    $newScopes = @($property.Value.oauth2PermissionScopes)
                    Assert-FakeEntitlementChange @($application.api.oauth2PermissionScopes) $newScopes 'scope' 'value', 'type', 'adminConsentDisplayName', 'adminConsentDescription'
                    $preAuthorized = @($property.Value.preAuthorizedApplications | ForEach-Object { $_.delegatedPermissionIds })
                    $missing = @($preAuthorized | Where-Object { $_ -notin @($newScopes.id) })
                    if ($missing.Count) { throw "Fake: pre-authorized scope $($missing -join ',') does not exist." }
                }
                $application.($property.Name) = $property.Value
            }
            $null
        }
        '^POST /applications/([^/]+)/addPassword$' {
            $application = $global:Fake.Applications[$Matches[1]]
            $credential = [pscustomobject]@{ keyId = New-FakeId; displayName = $body.passwordCredential.displayName; endDateTime = $body.passwordCredential.endDateTime }
            $application.passwordCredentials = @(@($application.passwordCredentials) + $credential)
            [pscustomobject]@{ keyId = $credential.keyId; displayName = $credential.displayName; endDateTime = $credential.endDateTime; secretText = "secret-for-$($application.displayName)" }
        }
        '^POST /applications/([^/]+)/removePassword$' {
            $application = $global:Fake.Applications[$Matches[1]]
            $application.passwordCredentials = @($application.passwordCredentials | Where-Object keyId -NE $body.keyId)
            $null
        }
        '^GET /(applications|servicePrincipals)/([^/]+)/owners$' { @{ value = @(@($global:Fake.Owners[$Matches[2]]) | Where-Object { $_ } | ForEach-Object { [pscustomobject]@{ id = $_ } }) } }
        '^POST /(applications|servicePrincipals)/([^/]+)/owners/\$ref$' {
            $owner = ($body.'@odata.id' -split '/')[-1]
            if (-not $global:Fake.Owners[$Matches[2]]) { $global:Fake.Owners[$Matches[2]] = [Collections.Generic.List[string]]::new() }
            if ($global:Fake.Owners[$Matches[2]].Contains($owner)) { throw 'Fake: owner already exists' }
            $global:Fake.Owners[$Matches[2]].Add($owner)
            $null
        }
        '^DELETE /(applications|servicePrincipals)/([^/]+)/owners/([^/]+)/\$ref$' { [void]$global:Fake.Owners[$Matches[2]].Remove($Matches[3]); $null }
        '^GET /servicePrincipals$' { @{ value = @($global:Fake.ServicePrincipals.Keys | ForEach-Object { Get-FakeServicePrincipal $_ } | Where-Object { -not $filter -or (Test-FakeFilter $_ $filter) }) } }
        '^POST /servicePrincipals$' {
            $application = $global:Fake.Applications.Values | Where-Object appId -EQ $body.appId | Select-Object -First 1
            if (-not $application) { throw "Fake: no application with appId $($body.appId)" }
            $id = New-FakeId
            $global:Fake.ServicePrincipals[$id] = [pscustomobject]@{ id = $id; appId = $body.appId; displayName = $application.displayName; appRoleAssignmentRequired = $false; appRoles = @(); oauth2PermissionScopes = @() }
            Get-FakeServicePrincipal $id
        }
        '^GET /servicePrincipals/([^/]+)$' {
            $sp = Get-FakeServicePrincipal $Matches[1]
            if ($query -match 'publishedPermissionScopes') { [pscustomobject]@{ publishedPermissionScopes = $sp.oauth2PermissionScopes } } else { $sp }
        }
        '^PATCH /servicePrincipals/([^/]+)$' {
            foreach ($property in $body.PSObject.Properties) { $global:Fake.ServicePrincipals[$Matches[1]].($property.Name) = $property.Value }
            $null
        }
        '^GET /servicePrincipals/([^/]+)/appRoleAssignedTo$' { @{ value = @($global:Fake.Assignments | Where-Object resourceId -EQ $Matches[1] | ForEach-Object { Copy-FakeObject $_ }) } }
        '^POST /servicePrincipals/([^/]+)/appRoleAssignedTo$' {
            $resource = Get-FakeServicePrincipal $Matches[1]
            if ($body.appRoleId -notin @($resource.appRoles.id)) { throw "Fake: role $($body.appRoleId) does not exist on $($resource.displayName)" }
            if (@($global:Fake.Assignments | Where-Object { $_.resourceId -eq $resource.id -and $_.appRoleId -eq $body.appRoleId -and $_.principalId -eq $body.principalId }).Count) {
                throw 'Fake: Permission being assigned already exists on the object'
            }
            $assignment = [pscustomobject]@{
                id = New-FakeId; appRoleId = $body.appRoleId; principalId = $body.principalId; resourceId = $resource.id
                principalDisplayName = Get-FakeDisplayName $body.principalId; principalType = Get-FakeType $body.principalId
            }
            $global:Fake.Assignments.Add($assignment)
            Copy-FakeObject $assignment
        }
        '^DELETE /servicePrincipals/([^/]+)/appRoleAssignedTo/([^/]+)$' {
            $assignment = $global:Fake.Assignments | Where-Object id -EQ $Matches[2] | Select-Object -First 1
            [void]$global:Fake.Assignments.Remove($assignment)
            $null
        }
        '^GET /servicePrincipals/([^/]+)/appRoleAssignments$' { @{ value = @($global:Fake.Assignments | Where-Object principalId -EQ $Matches[1] | ForEach-Object { Copy-FakeObject $_ }) } }
        '^GET /oauth2PermissionGrants$' { @{ value = @($global:Fake.Grants | Where-Object { Test-FakeFilter $_ $filter } | ForEach-Object { Copy-FakeObject $_ }) } }
        '^GET /users$' { @{ value = @($global:Fake.Users.Values | Where-Object { Test-FakeFilter $_ $filter } | ForEach-Object { Copy-FakeObject $_ }) } }
        '^GET /groups$' { @{ value = @($global:Fake.Groups.Values | Where-Object { Test-FakeFilter $_ $filter } | ForEach-Object { [pscustomobject]@{ id = $_.id; displayName = $_.displayName } }) } }
        '^GET /groups/([^/]+)/transitiveMembers$' {
            $seen = @{}
            $queue = [Collections.Generic.Queue[string]]::new([string[]]@($global:Fake.Groups[$Matches[1]].members))
            $members = while ($queue.Count) {
                $id = $queue.Dequeue()
                if ($seen.ContainsKey($id)) { continue }
                $seen[$id] = $true
                $type = Get-FakeType $id
                if ($type -eq 'Group') { $global:Fake.Groups[$id].members | ForEach-Object { $queue.Enqueue($_) } }
                [pscustomobject]@{ '@odata.type' = "#microsoft.graph.$($type.Substring(0,1).ToLower() + $type.Substring(1))"; id = $id; displayName = Get-FakeDisplayName $id }
            }
            @{ value = @($members) }
        }
        '^GET /me$' { [pscustomobject]@{ id = $global:Fake.Me } }
        default { throw "Fake: unsupported call $Method $Uri" }
    }

    if ($All) { return @($result.value) }
    $result
}

function Invoke-FakeAzCli {
    param([string[]] $Arguments, [switch] $AllowFailure)

    function Get-Argument([string] $Name) {
        $index = [array]::IndexOf($Arguments, $Name)
        if ($index -ge 0) { $Arguments[$index + 1] } else { $null }
    }
    function Get-Tags {
        $index = [array]::IndexOf($Arguments, '--tags')
        $tags = @{}
        if ($index -ge 0) { $Arguments[($index + 1)..($Arguments.Count - 1)] | Where-Object { $_ -match '^[^-][^=]*=' } | ForEach-Object { $k, $v = $_ -split '=', 2; $tags[$k] = $v } }
        $tags
    }

    $command = @($Arguments | Select-Object -First 3) -join ' '
    if ($command -notlike 'account show*' -and $command -notlike '* show') { $global:Fake.Writes.Add("az $command") }
    $vault = Get-Argument '--vault-name'
    $name = Get-Argument '--name'

    switch -Wildcard ($command) {
        'account show*' { return [pscustomobject]$global:Fake.Account }
        'keyvault certificate show' {
            $certificate = $global:Fake.Certificates["$vault/$name"]
            if (-not $certificate) { if ($AllowFailure) { return $null } throw 'Fake: certificate not found' }
            return [pscustomobject]@{ id = "https://$vault.vault.azure.net/certificates/$name"; tags = [pscustomobject]$certificate.Tags }
        }
        'keyvault certificate create' { $global:Fake.Certificates["$vault/$name"] = @{ Tags = Get-Tags }; return $null }
        'keyvault certificate set-attributes' { $global:Fake.Certificates["$vault/$name"].Tags = Get-Tags; return $null }
        'keyvault secret show' {
            if ($global:Fake.Secrets.ContainsKey("$vault/$name")) { return "https://$vault.vault.azure.net/secrets/$name" }
            if ($AllowFailure) { return $null }
            throw 'Fake: secret not found'
        }
        'keyvault secret set' {
            $global:Fake.Secrets["$vault/$name"] = Get-Content -LiteralPath (Get-Argument '--file') -Raw
            return "https://$vault.vault.azure.net/secrets/$name"
        }
        'ad app credential' {
            if ('--append' -notin $Arguments) { throw 'Fake: credential reset without --append removes every other credential' }
            $application = $global:Fake.Applications.Values | Where-Object appId -EQ (Get-Argument '--id') | Select-Object -First 1
            $application.keyCredentials = @(@($application.keyCredentials) + [pscustomobject]@{ keyId = New-FakeId; displayName = Get-Argument '--display-name' })
            return $null
        }
        default { throw "Fake: unsupported az $($Arguments -join ' ')" }
    }
}
