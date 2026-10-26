#Requires -Version 7.2
<#
.SYNOPSIS
    App registrations as code: read the definitions, resolve people and groups, and make Entra ID
    match — idempotently, with a dry run that shows every change first.

.DESCRIPTION
    Dot-source this file (and Graph.ps1). The scripts in the parent folder are thin wrappers.

    A run has three phases, because app registrations refer to each other:
      1. every application and service principal exists, with its roles, scopes, redirect URIs,
         credential, owners and settings;
      2. requested permissions and pre-authorized clients, which need the IDs from phase 1;
      3. role assignments: people, groups, managed identities, and the own applications that
         request a role.
#>

Set-StrictMode -Version Latest
. "$PSScriptRoot/Graph.ps1"

# Public, well-known application IDs that definitions may refer to by name.
$script:WellKnownApplications = @{
    'microsoft-graph'  = '00000003-0000-0000-c000-000000000000'
    'azure-cli'        = '04b07795-8ddb-461a-bbee-02f9e1bf7b46'
    'azure-powershell' = '1950a258-227b-4e31-a9cf-717495945fc2'
}

$script:GuidPattern = '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$'

#region Helpers

function Get-Value {
    <# Reads a key from a hashtable or a property from an object, with a default. StrictMode-safe. #>
    param($Object, [string] $Name, $Default = $null)
    if ($null -eq $Object) { return $Default }
    if ($Object -is [System.Collections.IDictionary]) {
        if ($Object.Contains($Name) -and $null -ne $Object[$Name]) { return $Object[$Name] }
        return $Default
    }
    $property = $Object.PSObject.Properties[$Name]
    if ($property -and $null -ne $property.Value) { return $property.Value }
    return $Default
}

function Test-HasKey {
    param($Object, [string] $Name)
    if ($Object -is [System.Collections.IDictionary]) { return $Object.Contains($Name) }
    return $null -ne $Object -and $null -ne $Object.PSObject.Properties[$Name]
}

function Copy-AsHashtable {
    <# A deep, mutable copy of a Graph object, for read-modify-write of complex properties. #>
    param($Object)
    if ($null -eq $Object) { return @{} }
    ConvertTo-Json -InputObject $Object -Depth 20 | ConvertFrom-Json -AsHashtable -Depth 20
}

function Test-Placeholder {
    <# During a dry run, objects that would be created carry IDs like 'new:orders-api'. #>
    param([string] $Id)
    $Id -like 'new:*'
}

function New-FilterUri {
    param([Parameter(Mandatory)][string] $Path, [Parameter(Mandatory)][string] $Filter, [string] $Select)
    $uri = "$Path`?`$filter=$([uri]::EscapeDataString($Filter))"
    if ($Select) { $uri += "&`$select=$Select" }
    $uri
}

function ConvertTo-KeyVaultName {
    <# Key Vault object names allow letters, digits and hyphens only. #>
    param([Parameter(Mandatory)][string] $Name)
    (($Name -replace '[^A-Za-z0-9-]', '-') -replace '-{2,}', '-').Trim('-')
}

function Compare-StringSet {
    <# True when both lists hold the same strings, ignoring order and duplicates. #>
    param([string[]] $Left, [string[]] $Right)
    $l = @($Left | Where-Object { $_ } | Sort-Object -Unique)
    $r = @($Right | Where-Object { $_ } | Sort-Object -Unique)
    ($l -join "`n") -ceq ($r -join "`n")
}

#endregion

#region Configuration

function Read-AppRegistrationConfiguration {
    <#
    .SYNOPSIS
        Reads the shared definitions and one environment file, and fills in the environment's tokens.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string] $DefinitionPath,
        [Parameter(Mandatory)][string] $EnvironmentPath
    )

    $environment = Get-Content -LiteralPath $EnvironmentPath -Raw | ConvertFrom-Json -AsHashtable
    $tokens = Get-Value $environment 'tokens' @{}
    $raw = Get-Content -LiteralPath $DefinitionPath -Raw

    $expanded = $raw
    foreach ($name in $tokens.Keys) {
        # Escape the value for use inside a JSON string.
        $value = (ConvertTo-Json -InputObject ([string]$tokens[$name])).Trim('"')
        $expanded = $expanded.Replace("#{$name}#", $value)
    }

    $unknown = @([regex]::Matches($expanded, '#\{([^}]+)\}#') | ForEach-Object { $_.Groups[1].Value } | Sort-Object -Unique)
    if ($unknown.Count -gt 0) {
        throw "Token(s) $($unknown -join ', ') are used in $DefinitionPath but not defined under 'tokens' in $EnvironmentPath."
    }

    $definition = $expanded | ConvertFrom-Json -AsHashtable
    $template = $raw | ConvertFrom-Json -AsHashtable

    [pscustomobject]@{
        Name                  = Get-Value $environment 'name' ([IO.Path]::GetFileNameWithoutExtension($EnvironmentPath))
        Tokens                = $tokens
        Applications          = @(Get-Value $definition 'appRegistrations' @())
        Templates             = @(Get-Value $template 'appRegistrations' @())
        Owners                = @(Get-Value $environment 'owners' @())
        ManageOwners          = [bool](Get-Value $environment 'manageOwners' $true)
        ManageRoleAssignments = [bool](Get-Value $environment 'manageRoleAssignments' $true)
        RoleMembers           = Get-Value $environment 'roleMembers' @{}
        RedirectUris          = Get-Value $environment 'redirectUris' @{}
        CertificatePolicyPath = Join-Path (Split-Path -Parent $DefinitionPath) 'certificate-policy.json'
    }
}

function Test-AppRegistrationConfiguration {
    <#
    .SYNOPSIS
        Checks a configuration without contacting Entra ID. Returns a list of problems; empty means valid.
    .DESCRIPTION
        Catches what JSON schema validation cannot: references between applications, to roles and
        scopes that do not exist, to redirect URI lists the environment lacks, and role members for
        roles nobody defines.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)] $Configuration)

    $problems = [Collections.Generic.List[string]]::new()
    $apps = @{}
    $displayNames = @{}

    foreach ($app in $Configuration.Applications) {
        $key = Get-Value $app 'key'
        $where = "Application '$key'"
        if ($key -notmatch '^[a-z0-9]+(-[a-z0-9]+)*$') { $problems.Add("$where`: key must be lower case letters, digits and hyphens.") }
        if ($apps.ContainsKey($key)) { $problems.Add("$where`: key is used twice.") }
        $apps[$key] = $app

        $displayName = Get-Value $app 'displayName' ''
        if ([string]::IsNullOrWhiteSpace($displayName)) { $problems.Add("$where`: displayName is required.") }
        elseif ($displayNames.ContainsKey($displayName)) { $problems.Add("$where`: displayName '$displayName' is also used by '$($displayNames[$displayName])'.") }
        else { $displayNames[$displayName] = $key }

        $values = @{}
        foreach ($role in @(Get-Value $app 'appRoles' @())) {
            $value = Get-Value $role 'value' ''
            if ($values.ContainsKey($value)) { $problems.Add("$where`: role or scope value '$value' is used twice.") }
            $values[$value] = $true
            $types = @(Get-Value $role 'allowedMemberTypes' @())
            if ($types.Count -eq 0 -or @($types | Where-Object { $_ -notin 'User', 'Application' }).Count -gt 0) {
                $problems.Add("$where`: role '$value' needs allowedMemberTypes with 'User' and/or 'Application'.")
            }
        }

        foreach ($scope in @(Get-Value $app 'scopes' @())) {
            $value = Get-Value $scope 'value' ''
            if ($values.ContainsKey($value)) { $problems.Add("$where`: role or scope value '$value' is used twice.") }
            $values[$value] = $true
        }

        $credential = Get-Value $app 'credential'
        if ($credential) {
            $type = Get-Value $credential 'type'
            if ($type -notin 'certificate', 'secret') { $problems.Add("$where`: credential type must be 'certificate' or 'secret'.") }
            if (-not (Get-Value $credential 'keyVault')) { $problems.Add("$where`: a $type credential needs a keyVault.") }
            if ($type -eq 'secret' -and -not (Get-Value $credential 'name')) { $problems.Add("$where`: a secret credential needs a name.") }
        }

        $redirects = Get-Value $app 'redirectUris' @{}
        foreach ($platform in $redirects.Keys) {
            if ($platform -notin 'spa', 'web', 'publicClient') { $problems.Add("$where`: redirect URI platform '$platform' must be spa, web or publicClient.") }
            $list = $redirects[$platform]
            if (-not $Configuration.RedirectUris.Contains($list)) {
                $problems.Add("$where`: redirect URI list '$list' is not defined in environment '$($Configuration.Name)'.")
            }
        }
    }

    foreach ($app in $Configuration.Applications) {
        $key = Get-Value $app 'key'
        foreach ($access in @(Get-Value $app 'requiredResourceAccess' @())) {
            $resource = Get-Value $access 'resource' ''
            if (-not $apps.ContainsKey($resource)) { continue }

            $target = $apps[$resource]
            $targetScopes = @(Get-Value $target 'scopes' @() | ForEach-Object { Get-Value $_ 'value' })
            foreach ($scope in @(Get-Value $access 'scopes' @())) {
                if ($scope -notin $targetScopes) { $problems.Add("Application '$key': requests scope '$scope' that '$resource' does not define.") }
            }

            foreach ($roleValue in @(Get-Value $access 'roles' @())) {
                $role = @(Get-Value $target 'appRoles' @()) | Where-Object { (Get-Value $_ 'value') -eq $roleValue } | Select-Object -First 1
                if (-not $role) { $problems.Add("Application '$key': requests role '$roleValue' that '$resource' does not define.") }
                elseif ('Application' -notin @(Get-Value $role 'allowedMemberTypes' @())) {
                    $problems.Add("Application '$key': requests role '$roleValue' of '$resource', which does not allow applications.")
                }
            }
        }

        $ownScopes = @(Get-Value $app 'scopes' @() | ForEach-Object { Get-Value $_ 'value' })
        foreach ($client in @(Get-Value $app 'preAuthorizedApplications' @())) {
            $application = Get-Value $client 'application' ''
            if ($application -notmatch $script:GuidPattern -and -not $script:WellKnownApplications.ContainsKey($application) -and -not $apps.ContainsKey($application)) {
                $problems.Add("Application '$key': pre-authorized application '$application' is not an own key, a well-known name or an application ID.")
            }
            foreach ($scope in @(Get-Value $client 'scopes' @())) {
                if ($scope -notin $ownScopes) { $problems.Add("Application '$key': pre-authorizes scope '$scope' that it does not define.") }
            }
        }
    }

    foreach ($memberKey in $Configuration.RoleMembers.Keys) {
        $appKey, $roleValue = if ($memberKey -match '^([^/]+)/(.+)$') { $Matches[1], $Matches[2] } else { $null, $memberKey }
        $candidates = if ($appKey) { @($apps[$appKey]) | Where-Object { $_ } } else { $apps.Values }
        if ($appKey -and -not $apps.ContainsKey($appKey)) {
            $problems.Add("Environment '$($Configuration.Name)': role members '$memberKey' refer to unknown application '$appKey'.")
            continue
        }

        $defined = @($candidates | Where-Object { @(Get-Value $_ 'appRoles' @() | ForEach-Object { Get-Value $_ 'value' }) -contains $roleValue })
        if ($defined.Count -eq 0) {
            $problems.Add("Environment '$($Configuration.Name)': role members '$memberKey' refer to a role no application defines.")
        }
    }

    if ($Configuration.ManageOwners -and $Configuration.Owners.Count -eq 0) {
        $problems.Add("Environment '$($Configuration.Name)': owners is empty; set manageOwners to false to leave owners alone.")
    }

    $problems.ToArray()
}

#endregion

#region Principals

function Initialize-RunState {
    param([switch] $DryRun)
    $script:DryRun = [bool]$DryRun
    $script:Changes = [Collections.Generic.List[object]]::new()
    $script:PrincipalCache = @{}
    $script:MembersCache = @{}
    $script:ResourceCache = @{}
    $script:CurrentIdentityId = $null
}

function Invoke-Change {
    <#
    .SYNOPSIS
        Records a change and carries it out, unless this is a dry run.
    #>
    param(
        [Parameter(Mandatory)][string] $Target,
        [Parameter(Mandatory)][string] $Action,
        [Parameter(Mandatory)][scriptblock] $Script
    )
    $script:Changes.Add([pscustomobject]@{ Target = $Target; Action = $Action })
    if ($script:DryRun) {
        Write-Information "  [plan] $Target`: $Action"
        return $null
    }

    Write-Information "  [change] $Target`: $Action"
    & $Script
}

function Resolve-Principal {
    <#
    .SYNOPSIS
        Finds a user (by UPN), group or service principal (by display name).
    .DESCRIPTION
        Prefix a name to say what it is: 'user:', 'group:' or 'sp:'. Without a prefix, a name with
        '@' is tried as a user first; then groups, then service principals. A name that matches
        more than one object of the same kind is an error: assigning access must not be a guess.
    #>
    param(
        [Parameter(Mandatory)][string] $Name,
        [switch] $AllowUnresolved
    )

    if ($script:PrincipalCache.ContainsKey($Name)) { return $script:PrincipalCache[$Name] }

    $kind, $lookup = if ($Name -match '^(user|group|sp):(.+)$') { $Matches[1], $Matches[2] } else { $null, $Name }
    $order = if ($kind) { @($kind) } elseif ($lookup -like '*@*') { @('user', 'group', 'sp') } else { @('group', 'sp', 'user') }

    foreach ($candidate in $order) {
        $quoted = ConvertTo-ODataString $lookup
        $found = @(switch ($candidate) {
            'user' { Invoke-Graph -Uri (New-FilterUri '/users' "userPrincipalName eq $quoted" 'id,displayName,userPrincipalName') -All }
            'group' { Invoke-Graph -Uri (New-FilterUri '/groups' "displayName eq $quoted" 'id,displayName') -All }
            'sp' { Invoke-Graph -Uri (New-FilterUri '/servicePrincipals' "displayName eq $quoted" 'id,displayName,appId') -All }
        })

        if ($found.Count -gt 1) {
            throw "Principal '$Name' matches $($found.Count) objects of type $candidate. Make the name unique, or use the object ID."
        }

        if ($found.Count -eq 1) {
            $principal = [pscustomobject]@{
                Id          = $found[0].id
                Type        = @{ user = 'User'; group = 'Group'; sp = 'ServicePrincipal' }[$candidate]
                DisplayName = $found[0].displayName
                Name        = $Name
            }
            $script:PrincipalCache[$Name] = $principal
            return $principal
        }
    }

    if ($AllowUnresolved) {
        Write-Warning "Principal '$Name' not found; skipping it."
        return $null
    }

    throw "Principal '$Name' was not found as a user, group or service principal. A missing name would silently remove access, so the run stops. Use -AllowUnresolvedPrincipals to skip it instead."
}

function Get-GroupMembers {
    <# Users and service principals in a group, including nested groups. #>
    param([Parameter(Mandatory)][string] $GroupId)
    if (-not $script:MembersCache.ContainsKey($GroupId)) {
        $members = @(Invoke-Graph -Uri "/groups/$GroupId/transitiveMembers?`$select=id,displayName" -All)
        $script:MembersCache[$GroupId] = @($members | ForEach-Object {
                $type = switch ($_.'@odata.type') {
                    '#microsoft.graph.user' { 'User' }
                    '#microsoft.graph.servicePrincipal' { 'ServicePrincipal' }
                    default { $null }
                }
                if ($type) { [pscustomobject]@{ Id = $_.id; Type = $type; DisplayName = $_.displayName; Name = $_.displayName } }
            })
    }
    $script:MembersCache[$GroupId]
}

function Resolve-Owners {
    <#
    .SYNOPSIS
        Owners must be users or service principals, so groups are expanded to their members.
    #>
    param([string[]] $Names, [switch] $AllowUnresolved)
    $owners = foreach ($name in $Names) {
        $principal = Resolve-Principal -Name $name -AllowUnresolved:$AllowUnresolved
        if (-not $principal) { continue }
        if ($principal.Type -eq 'Group') { Get-GroupMembers -GroupId $principal.Id } else { $principal }
    }
    @($owners | Sort-Object Id -Unique)
}

function Resolve-RoleMembers {
    <#
    .SYNOPSIS
        A group is assigned as itself, so its users get the role. Service principals in a group are
        assigned directly as well: app-only tokens do not carry roles assigned through groups.
        Those are marked ViaGroup; a role that does not allow applications skips them.
    #>
    param([string[]] $Names, [switch] $AllowUnresolved)
    $members = foreach ($name in $Names) {
        $principal = Resolve-Principal -Name $name -AllowUnresolved:$AllowUnresolved
        if (-not $principal) { continue }
        [pscustomobject]@{ Id = $principal.Id; Type = $principal.Type; DisplayName = $principal.DisplayName; Name = $principal.Name; ViaGroup = $false }
        if ($principal.Type -eq 'Group') {
            Get-GroupMembers -GroupId $principal.Id | Where-Object Type -EQ 'ServicePrincipal' | ForEach-Object {
                [pscustomobject]@{ Id = $_.Id; Type = $_.Type; DisplayName = $_.DisplayName; Name = "$($_.Name) (in $name)"; ViaGroup = $true }
            }
        }
    }
    # A principal listed by name wins over the same principal found through a group.
    @($members | Sort-Object ViaGroup | Group-Object Id | ForEach-Object { $_.Group[0] })
}

function Get-CurrentIdentityId {
    <# The identity running the script; always kept as owner, so it cannot lock itself out. #>
    if (-not $script:CurrentIdentityId) {
        $account = Invoke-AzCli -Arguments @('account', 'show')
        $script:CurrentIdentityId = if ($account.user.type -eq 'servicePrincipal') {
            $sp = @(Invoke-Graph -Uri (New-FilterUri '/servicePrincipals' "appId eq $(ConvertTo-ODataString $account.user.name)" 'id') -All) | Select-Object -First 1
            if (-not $sp) { throw "The signed-in service principal with application ID '$($account.user.name)' was not found." }
            $sp.id
        }
        else {
            (Invoke-Graph -Uri '/me?$select=id').id
        }
    }
    $script:CurrentIdentityId
}

#endregion

#region Phase 1: applications and service principals

function New-PlaceholderApplication {
    param([string] $Key, [string] $DisplayName)
    [pscustomobject]@{
        id                     = "new:$Key"
        appId                  = "new:$Key"
        displayName            = $DisplayName
        identifierUris         = @()
        appRoles               = @()
        api                    = [pscustomobject]@{ requestedAccessTokenVersion = 2; oauth2PermissionScopes = @(); preAuthorizedApplications = @() }
        spa                    = [pscustomobject]@{ redirectUris = @() }
        web                    = [pscustomobject]@{ redirectUris = @() }
        publicClient           = [pscustomobject]@{ redirectUris = @() }
        keyCredentials         = @()
        passwordCredentials    = @()
        requiredResourceAccess = @()
    }
}

function Get-DesiredPermissions {
    <# Desired roles or scopes with stable IDs: an existing ID is kept for the same value. #>
    param([object[]] $Desired, [object[]] $Existing, [ValidateSet('role', 'scope')][string] $Kind)
    foreach ($item in $Desired) {
        $value = Get-Value $item 'value'
        $match = @($Existing | Where-Object { $_.value -eq $value }) | Select-Object -First 1
        $result = [ordered]@{
            id        = if ($match) { $match.id } else { (New-Guid).Guid }
            value     = $value
            isEnabled = [bool](Get-Value $item 'isEnabled' $true)
        }
        if ($Kind -eq 'role') {
            $result.displayName = Get-Value $item 'displayName' $value
            $result.description = Get-Value $item 'description' (Get-Value $item 'displayName' $value)
            $result.allowedMemberTypes = @(Get-Value $item 'allowedMemberTypes' @())
        }
        else {
            $result.type = Get-Value $item 'type' 'User'
            $result.adminConsentDisplayName = Get-Value $item 'adminConsentDisplayName' $value
            $result.adminConsentDescription = Get-Value $item 'adminConsentDescription' (Get-Value $item 'adminConsentDisplayName' $value)
            $result.userConsentDisplayName = Get-Value $item 'userConsentDisplayName'
            $result.userConsentDescription = Get-Value $item 'userConsentDescription'
        }
        $result
    }
}

function Get-PermissionDifference {
    <# Which values are new, changed or removed between desired and existing roles or scopes. #>
    param([object[]] $Desired, [object[]] $Existing, [string[]] $Properties)
    $signature = { param($p) ($Properties | ForEach-Object { $v = Get-Value $p $_; if ($v -is [array]) { ($v | Sort-Object) -join ',' } else { "$v" } }) -join '|' }
    $existingByValue = @{}
    foreach ($e in $Existing) { $existingByValue[$e.value] = $e }
    $desiredValues = @($Desired | ForEach-Object { $_.value })

    [pscustomobject]@{
        New     = @($Desired | Where-Object { -not $existingByValue.ContainsKey($_.value) } | ForEach-Object { $_.value })
        Changed = @($Desired | Where-Object { $existingByValue.ContainsKey($_.value) -and (& $signature $_) -ne (& $signature $existingByValue[$_.value]) } | ForEach-Object { $_.value })
        Removed = @($Existing | Where-Object { $_.value -notin $desiredValues } | ForEach-Object { $_.value })
    }
}

function Sync-AppRoles {
    param($Application, $Definition)
    if (-not (Test-HasKey $Definition 'appRoles')) { return }

    $existing = @($Application.appRoles)
    $desired = @(Get-DesiredPermissions -Desired @(Get-Value $Definition 'appRoles' @()) -Existing $existing -Kind role)
    $diff = Get-PermissionDifference -Desired $desired -Existing $existing -Properties 'displayName', 'description', 'allowedMemberTypes', 'isEnabled'
    if (($diff.New.Count + $diff.Changed.Count + $diff.Removed.Count) -eq 0) { return }

    # Entra ID refuses to change or delete an enabled role: disable those first.
    $toDisable = @($existing | Where-Object { $_.isEnabled -and ($_.value -in $diff.Changed -or $_.value -in $diff.Removed) })
    if ($toDisable.Count -gt 0) {
        $disabled = @($existing | ForEach-Object { $r = Copy-AsHashtable $_; if ($r.value -in $toDisable.value) { $r.isEnabled = $false }; $r })
        Invoke-Change -Target $Application.displayName -Action "disable role(s) $($toDisable.value -join ', ') before changing them" -Script {
            Invoke-Graph -Method PATCH -Uri "/applications/$($Application.id)" -Body @{ appRoles = $disabled } | Out-Null
        } | Out-Null
    }

    $summary = @(
        if ($diff.New.Count) { "add $($diff.New -join ', ')" }
        if ($diff.Changed.Count) { "update $($diff.Changed -join ', ')" }
        if ($diff.Removed.Count) { "remove $($diff.Removed -join ', ')" }
    ) -join '; '
    Invoke-Change -Target $Application.displayName -Action "roles: $summary" -Script {
        Invoke-Graph -Method PATCH -Uri "/applications/$($Application.id)" -Body @{ appRoles = $desired } | Out-Null
    } | Out-Null
}

function Sync-Api {
    <# Scopes and the v2 token setting. The api object is always written whole, never partially. #>
    param($Application, $Definition)
    $api = Copy-AsHashtable $Application.api
    $existingScopes = @(Get-Value $Application.api 'oauth2PermissionScopes' @())
    $tokenVersionOk = (Get-Value $Application.api 'requestedAccessTokenVersion') -eq 2

    $manageScopes = Test-HasKey $Definition 'scopes'
    $diff = $null
    $desired = @()
    if ($manageScopes) {
        $desired = @(Get-DesiredPermissions -Desired @(Get-Value $Definition 'scopes' @()) -Existing $existingScopes -Kind scope)
        $diff = Get-PermissionDifference -Desired $desired -Existing $existingScopes -Properties 'type', 'adminConsentDisplayName', 'adminConsentDescription', 'userConsentDisplayName', 'userConsentDescription', 'isEnabled'
    }

    $scopesChange = $manageScopes -and ($diff.New.Count + $diff.Changed.Count + $diff.Removed.Count) -gt 0
    if (-not $scopesChange -and $tokenVersionOk) { return }

    if ($scopesChange) {
        $toDisable = @($existingScopes | Where-Object { $_.isEnabled -and ($_.value -in $diff.Changed -or $_.value -in $diff.Removed) })
        if ($toDisable.Count -gt 0) {
            $removedIds = @($existingScopes | Where-Object { $_.value -in $diff.Removed } | ForEach-Object { $_.id })
            $step = Copy-AsHashtable $Application.api
            $step.oauth2PermissionScopes = @($existingScopes | ForEach-Object { $s = Copy-AsHashtable $_; if ($s.value -in $toDisable.value) { $s.isEnabled = $false }; $s })
            # A scope that is still pre-authorized cannot be removed.
            $step.preAuthorizedApplications = @(@(Get-Value $step 'preAuthorizedApplications' @()) | ForEach-Object {
                    $_.delegatedPermissionIds = @($_.delegatedPermissionIds | Where-Object { $_ -notin $removedIds }); $_
                } | Where-Object { $_.delegatedPermissionIds.Count -gt 0 })
            Invoke-Change -Target $Application.displayName -Action "disable scope(s) $($toDisable.value -join ', ') before changing them" -Script {
                Invoke-Graph -Method PATCH -Uri "/applications/$($Application.id)" -Body @{ api = $step } | Out-Null
            } | Out-Null
            $api.preAuthorizedApplications = $step.preAuthorizedApplications
        }
        $api.oauth2PermissionScopes = $desired
    }

    $api.requestedAccessTokenVersion = 2
    $action = @(
        if ($scopesChange) { "scopes: $(@(
            if ($diff.New.Count) { "add $($diff.New -join ', ')" }
            if ($diff.Changed.Count) { "update $($diff.Changed -join ', ')" }
            if ($diff.Removed.Count) { "remove $($diff.Removed -join ', ')" }) -join '; ')" }
        if (-not $tokenVersionOk) { 'issue v2 access tokens' }
    ) -join '; '
    Invoke-Change -Target $Application.displayName -Action $action -Script {
        Invoke-Graph -Method PATCH -Uri "/applications/$($Application.id)" -Body @{ api = $api } | Out-Null
    } | Out-Null
}

function Sync-RedirectUris {
    param($Application, $Definition, $Configuration)
    $redirects = Get-Value $Definition 'redirectUris' @{}
    foreach ($platform in @('spa', 'web', 'publicClient')) {
        if (-not $redirects.Contains($platform)) { continue }
        $listName = $redirects[$platform]
        if (-not $Configuration.RedirectUris.Contains($listName)) {
            throw "Redirect URI list '$listName' is not defined in environment '$($Configuration.Name)'."
        }

        $desired = @($Configuration.RedirectUris[$listName])
        $current = @(Get-Value (Get-Value $Application $platform) 'redirectUris' @())
        if (Compare-StringSet $desired $current) { continue }

        $body = Copy-AsHashtable (Get-Value $Application $platform)
        $body.redirectUris = $desired
        $body.Remove('redirectUriSettings')
        Invoke-Change -Target $Application.displayName -Action "$platform redirect URIs: $($desired -join ', ')" -Script {
            Invoke-Graph -Method PATCH -Uri "/applications/$($Application.id)" -Body @{ $platform = $body } | Out-Null
        } | Out-Null
    }
}

function Sync-Credential {
    param($Application, $Definition, $Configuration)
    $credential = Get-Value $Definition 'credential'
    if (-not $credential) { return }

    $vault = Get-Value $credential 'keyVault'
    if ((Get-Value $credential 'type') -eq 'certificate') {
        $name = ConvertTo-KeyVaultName "AppReg-$($Application.displayName)"
        $onApp = @($Application.keyCredentials | Where-Object { "$($_.displayName)" -like "$name*" }).Count -gt 0
        $inVault = Invoke-AzCli -Arguments @('keyvault', 'certificate', 'show', '--vault-name', $vault, '--name', $name, '--query', '{id:id,tags:tags}') -AllowFailure

        if (-not $inVault) {
            $tags = Get-Value $credential 'tags' @{}
            $tagArguments = if ($tags.Count) { @('--tags') + @($tags.Keys | ForEach-Object { "$_=$($tags[$_])" }) } else { @() }
            Invoke-Change -Target $Application.displayName -Action "create certificate '$name' in Key Vault '$vault'" -Script {
                Invoke-AzCli -Arguments (@('keyvault', 'certificate', 'create', '--vault-name', $vault, '--name', $name, '--policy', "@$($Configuration.CertificatePolicyPath)") + $tagArguments) | Out-Null
            } | Out-Null
        }
        else {
            Sync-CertificateTags -Application $Application -Vault $vault -Name $name -Current (Get-Value $inVault 'tags' @{}) -Desired (Get-Value $credential 'tags' @{})
        }

        if (-not $onApp) {
            # --append keeps the other credentials; without it, the CLI replaces them all.
            Invoke-Change -Target $Application.displayName -Action "add certificate '$name' as client credential" -Script {
                Invoke-AzCli -Arguments @('ad', 'app', 'credential', 'reset', '--id', $Application.appId, '--keyvault', $vault, '--cert', $name, '--append', '--display-name', $name) | Out-Null
            } | Out-Null
        }
        return
    }

    $credentialName = Get-Value $credential 'name'
    $secretName = ConvertTo-KeyVaultName "AppReg-$($Application.displayName)-$credentialName"
    $onApp = @($Application.passwordCredentials | Where-Object { $_.displayName -eq $credentialName }).Count -gt 0
    if ($onApp) {
        $inVault = Invoke-AzCli -Arguments @('keyvault', 'secret', 'show', '--vault-name', $vault, '--name', $secretName, '--query', 'id') -AllowFailure
        if (-not $inVault) {
            Write-Warning "$($Application.displayName): client secret '$credentialName' exists, but Key Vault '$vault' has no secret '$secretName'. Its value cannot be read back; delete the client secret to have a new one created and stored."
        }
        return
    }

    $months = [int](Get-Value $credential 'validityInMonths' 12)
    Invoke-Change -Target $Application.displayName -Action "add client secret '$credentialName' and store it in Key Vault '$vault' as '$secretName'" -Script {
        $password = Invoke-Graph -Method POST -Uri "/applications/$($Application.id)/addPassword" -Body @{
            passwordCredential = @{ displayName = $credentialName; endDateTime = [DateTime]::UtcNow.AddMonths($months).ToString('o') }
        }
        $file = New-TemporaryFile
        try {
            Set-Content -LiteralPath $file -Value $password.secretText -NoNewline -Encoding utf8NoBOM
            Invoke-AzCli -Arguments @('keyvault', 'secret', 'set', '--vault-name', $vault, '--name', $secretName, '--file', $file, '--encoding', 'utf-8', '--expires', $password.endDateTime, '--query', 'id') | Out-Null
        }
        catch {
            # A secret nobody can read is useless and blocks a retry: take it back off the application.
            Invoke-Graph -Method POST -Uri "/applications/$($Application.id)/removePassword" -Body @{ keyId = $password.keyId } | Out-Null
            throw
        }
        finally {
            Remove-Item -LiteralPath $file -Force -ErrorAction SilentlyContinue
        }
    } | Out-Null
}

function Sync-CertificateTags {
    param($Application, [string] $Vault, [string] $Name, $Current, $Desired)
    if ($Desired.Count -eq 0) { return }
    $merged = @{}
    if ($Current) { foreach ($p in @(if ($Current -is [System.Collections.IDictionary]) { $Current.Keys } else { $Current.PSObject.Properties.Name })) { $merged[$p] = Get-Value $Current $p } }
    $stale = @($Desired.Keys | Where-Object { "$(Get-Value $Current $_)" -ne "$($Desired[$_])" })
    if ($stale.Count -eq 0) { return }
    foreach ($k in $Desired.Keys) { $merged[$k] = $Desired[$k] }
    Invoke-Change -Target $Application.displayName -Action "update tag(s) $($stale -join ', ') of certificate '$Name'" -Script {
        Invoke-AzCli -Arguments (@('keyvault', 'certificate', 'set-attributes', '--vault-name', $Vault, '--name', $Name, '--tags') + @($merged.Keys | ForEach-Object { "$_=$($merged[$_])" })) | Out-Null
    } | Out-Null
}

function Sync-Owners {
    param([string] $Label, [string] $Path, [string[]] $DesiredIds)
    $current = if (Test-Placeholder $Path) { @() } else { @(Invoke-Graph -Uri "$Path/owners?`$select=id" -All | ForEach-Object { $_.id }) }
    foreach ($id in @($DesiredIds | Where-Object { $_ -notin $current })) {
        Invoke-Change -Target $Label -Action "add owner $id" -Script {
            Invoke-Graph -Method POST -Uri "$Path/owners/`$ref" -Body @{ '@odata.id' = "https://graph.microsoft.com/v1.0/directoryObjects/$id" } | Out-Null
        } | Out-Null
    }
    foreach ($id in @($current | Where-Object { $_ -notin $DesiredIds })) {
        Invoke-Change -Target $Label -Action "remove owner $id" -Script {
            Invoke-Graph -Method DELETE -Uri "$Path/owners/$id/`$ref" | Out-Null
        } | Out-Null
    }
}

function Sync-Application {
    <#
    .SYNOPSIS
        Phase 1 for one definition. Returns the application and its service principal.
    #>
    param($Definition, $Configuration, [string[]] $OwnerIds)

    $key = Get-Value $Definition 'key'
    $displayName = Get-Value $Definition 'displayName'
    Write-Information "$displayName ($key)"

    $found = @(Invoke-Graph -Uri (New-FilterUri '/applications' "displayName eq $(ConvertTo-ODataString $displayName)") -All)
    if ($found.Count -gt 1) {
        throw "There are $($found.Count) applications named '$displayName'. Display names identify applications here; remove or rename the duplicates."
    }

    $application = if ($found.Count -eq 1) { $found[0] } else {
        $created = Invoke-Change -Target $displayName -Action 'create application' -Script {
            Invoke-Graph -Method POST -Uri '/applications' -Body @{
                displayName    = $displayName
                signInAudience = 'AzureADMyOrg'
                api            = @{ requestedAccessTokenVersion = 2 }
            }
        }
        if ($created) { $created } else { New-PlaceholderApplication -Key $key -DisplayName $displayName }
    }

    $identifierUri = "api://$($application.appId)"
    if ($identifierUri -notin @($application.identifierUris)) {
        $uris = @(@($application.identifierUris) + $identifierUri | Where-Object { $_ })
        Invoke-Change -Target $displayName -Action "set identifier URI $identifierUri" -Script {
            Invoke-Graph -Method PATCH -Uri "/applications/$($application.id)" -Body @{ identifierUris = $uris } | Out-Null
        } | Out-Null
    }

    Sync-AppRoles -Application $application -Definition $Definition
    Sync-Api -Application $application -Definition $Definition
    Sync-RedirectUris -Application $application -Definition $Definition -Configuration $Configuration
    Sync-Credential -Application $application -Definition $Definition -Configuration $Configuration

    $servicePrincipal = if (Test-Placeholder $application.appId) { $null } else {
        @(Invoke-Graph -Uri (New-FilterUri '/servicePrincipals' "appId eq $(ConvertTo-ODataString $application.appId)") -All) | Select-Object -First 1
    }
    if (-not $servicePrincipal) {
        $servicePrincipal = Invoke-Change -Target $displayName -Action 'create service principal' -Script {
            Invoke-Graph -Method POST -Uri '/servicePrincipals' -Body @{ appId = $application.appId }
        }
        if (-not $servicePrincipal) { $servicePrincipal = [pscustomobject]@{ id = "new:$key-sp"; appId = $application.appId; appRoleAssignmentRequired = $false; appRoles = @() } }
    }

    $assignmentRequired = [bool](Get-Value $Definition 'assignmentRequired' $true)
    if ([bool]$servicePrincipal.appRoleAssignmentRequired -ne $assignmentRequired) {
        Invoke-Change -Target $displayName -Action "set 'assignment required' to $assignmentRequired" -Script {
            Invoke-Graph -Method PATCH -Uri "/servicePrincipals/$($servicePrincipal.id)" -Body @{ appRoleAssignmentRequired = $assignmentRequired } | Out-Null
        } | Out-Null
    }

    if ($Configuration.ManageOwners) {
        Sync-Owners -Label "$displayName (application)" -Path "/applications/$($application.id)" -DesiredIds $OwnerIds
        Sync-Owners -Label "$displayName (service principal)" -Path "/servicePrincipals/$($servicePrincipal.id)" -DesiredIds $OwnerIds
    }

    # Read back what phase 2 and 3 build on: role and scope IDs, the service principal's roles.
    if (-not (Test-Placeholder $application.id) -and -not $script:DryRun) {
        $application = Invoke-Graph -Uri "/applications/$($application.id)"
        $servicePrincipal = Invoke-Graph -Uri "/servicePrincipals/$($servicePrincipal.id)"
    }

    [pscustomobject]@{ Key = $key; Definition = $Definition; Application = $application; ServicePrincipal = $servicePrincipal }
}

#endregion

#region Phase 2: requested permissions and pre-authorized clients

function Resolve-Resource {
    <#
    .SYNOPSIS
        Finds what a requiredResourceAccess entry points at: an own application (by key), a
        well-known application (by name), any application (by ID) or another team's (by display name).
    #>
    param([Parameter(Mandatory)][string] $Resource, [hashtable] $Synced)

    if ($Synced -and $Synced.ContainsKey($Resource)) {
        $own = $Synced[$Resource]
        $definition = $own.Definition
        $application = $own.Application
        $existingRoles = @($application.appRoles)
        $existingScopes = @(Get-Value $application.api 'oauth2PermissionScopes' @())

        # In a dry run, permissions of new applications have no IDs yet.
        $roleMap = @{}
        foreach ($role in @(Get-Value $definition 'appRoles' @())) {
            $value = Get-Value $role 'value'
            $existingRole = @($existingRoles | Where-Object { $_.value -eq $value }) | Select-Object -First 1
            $roleMap[$value] = [pscustomobject]@{
                Id                 = if ($existingRole) { $existingRole.id } else { "new:$value" }
                AllowsApplications = 'Application' -in @(Get-Value $role 'allowedMemberTypes' @())
            }
        }

        $scopeMap = @{}
        foreach ($scope in @(Get-Value $definition 'scopes' @())) {
            $value = Get-Value $scope 'value'
            $existingScope = @($existingScopes | Where-Object { $_.value -eq $value }) | Select-Object -First 1
            $scopeMap[$value] = if ($existingScope) { $existingScope.id } else { "new:$value" }
        }

        return [pscustomobject]@{
            AppId       = $application.appId
            DisplayName = $application.displayName
            Key         = $Resource
            Own         = $own
            Roles       = $roleMap
            Scopes      = $scopeMap
        }
    }

    if ($script:ResourceCache.ContainsKey($Resource)) { return $script:ResourceCache[$Resource] }

    $appId = if ($script:WellKnownApplications.ContainsKey($Resource)) { $script:WellKnownApplications[$Resource] } elseif ($Resource -match $script:GuidPattern) { $Resource } else { $null }
    $filter = if ($appId) { "appId eq $(ConvertTo-ODataString $appId)" } else { "displayName eq $(ConvertTo-ODataString $Resource)" }
    $found = @(Invoke-Graph -Uri (New-FilterUri '/servicePrincipals' $filter 'id,appId,displayName,appRoles,oauth2PermissionScopes') -All)
    if ($found.Count -ne 1) {
        throw "Resource '$Resource' matches $($found.Count) service principals; it must match exactly one."
    }

    $servicePrincipal = $found[0]
    $scopes = @($servicePrincipal.oauth2PermissionScopes)
    if ($scopes.Count -eq 0) {
        # v1.0 leaves the scopes of some first-party applications empty; beta has them.
        $scopes = @((Invoke-Graph -Uri "https://graph.microsoft.com/beta/servicePrincipals/$($servicePrincipal.id)?`$select=publishedPermissionScopes").publishedPermissionScopes)
    }

    $roleMap = @{}
    foreach ($r in @($servicePrincipal.appRoles)) { $roleMap[$r.value] = [pscustomobject]@{ Id = $r.id; AllowsApplications = 'Application' -in @($r.allowedMemberTypes) } }
    $scopeMap = @{}
    foreach ($s in $scopes) { $scopeMap[$s.value] = $s.id }

    $resolved = [pscustomobject]@{
        AppId            = $servicePrincipal.appId
        DisplayName      = $servicePrincipal.displayName
        Key              = $Resource
        Own              = $null
        ServicePrincipal = $servicePrincipal
        Roles            = $roleMap
        Scopes           = $scopeMap
    }
    $script:ResourceCache[$Resource] = $resolved
    $resolved
}

function Get-DesiredResourceAccess {
    param($Definition, [hashtable] $Synced)
    foreach ($access in @(Get-Value $Definition 'requiredResourceAccess' @())) {
        $resource = Resolve-Resource -Resource (Get-Value $access 'resource') -Synced $Synced
        $items = @(
            foreach ($scope in @(Get-Value $access 'scopes' @())) {
                if (-not $resource.Scopes.ContainsKey($scope)) { throw "'$($resource.DisplayName)' has no scope '$scope'." }
                [ordered]@{ id = $resource.Scopes[$scope]; type = 'Scope' }
            }
            foreach ($role in @(Get-Value $access 'roles' @())) {
                if (-not $resource.Roles.ContainsKey($role)) { throw "'$($resource.DisplayName)' has no role '$role'." }
                if (-not $resource.Roles[$role].AllowsApplications) { throw "Role '$role' of '$($resource.DisplayName)' cannot be granted to applications." }
                [ordered]@{ id = $resource.Roles[$role].Id; type = 'Role' }
            }
        )
        [ordered]@{ resourceAppId = $resource.AppId; resourceAccess = $items }
    }
}

function ConvertTo-AccessSignature {
    param([object[]] $Access)
    @($Access | ForEach-Object {
            $appId = Get-Value $_ 'resourceAppId'
            @(Get-Value $_ 'resourceAccess' @()) | ForEach-Object { "$appId|$(Get-Value $_ 'type')|$(Get-Value $_ 'id')" }
        } | Sort-Object) -join "`n"
}

function Sync-Permissions {
    <# Phase 2 for one application. #>
    param($Synced, [hashtable] $All)
    $definition = $Synced.Definition
    $application = $Synced.Application

    if (Test-HasKey $definition 'requiredResourceAccess') {
        $desired = @(Get-DesiredResourceAccess -Definition $definition -Synced $All)
        if ((ConvertTo-AccessSignature $desired) -ne (ConvertTo-AccessSignature @($application.requiredResourceAccess))) {
            $summary = @(@(Get-Value $definition 'requiredResourceAccess' @()) | ForEach-Object { "$(Get-Value $_ 'resource') ($(@(@(Get-Value $_ 'scopes' @()) + @(Get-Value $_ 'roles' @())) -join ', '))" }) -join '; '
            Invoke-Change -Target $application.displayName -Action "requested permissions: $summary" -Script {
                Invoke-Graph -Method PATCH -Uri "/applications/$($application.id)" -Body @{ requiredResourceAccess = $desired } | Out-Null
            } | Out-Null
        }
    }

    if (Test-HasKey $definition 'preAuthorizedApplications') {
        $scopeIds = @{}
        foreach ($s in @(Get-Value $application.api 'oauth2PermissionScopes' @())) { $scopeIds[$s.value] = $s.id }
        $desired = @(foreach ($client in @(Get-Value $definition 'preAuthorizedApplications' @())) {
                $name = Get-Value $client 'application'
                $appId = if ($All.ContainsKey($name)) { $All[$name].Application.appId } elseif ($script:WellKnownApplications.ContainsKey($name)) { $script:WellKnownApplications[$name] } else { $name }
                [ordered]@{
                    appId                  = $appId
                    delegatedPermissionIds = @(Get-Value $client 'scopes' @() | ForEach-Object { if ($scopeIds.ContainsKey($_)) { $scopeIds[$_] } else { "new:$_" } })
                }
            })

        $signature = { param($list) @($list | ForEach-Object { $a = Get-Value $_ 'appId'; @(Get-Value $_ 'delegatedPermissionIds' @()) | ForEach-Object { "$a|$_" } } | Sort-Object) -join "`n" }
        if ((& $signature $desired) -ne (& $signature @(Get-Value $application.api 'preAuthorizedApplications' @()))) {
            $api = Copy-AsHashtable $application.api
            $api.preAuthorizedApplications = $desired
            $names = @(Get-Value $definition 'preAuthorizedApplications' @() | ForEach-Object { Get-Value $_ 'application' }) -join ', '
            Invoke-Change -Target $application.displayName -Action "pre-authorized clients: $names" -Script {
                Invoke-Graph -Method PATCH -Uri "/applications/$($application.id)" -Body @{ api = $api } | Out-Null
            } | Out-Null
        }
    }
}

#endregion

#region Phase 3: role assignments

function Get-RoleMemberNames {
    param($Configuration, [string] $AppKey, [string] $RoleValue)
    @(
        @(Get-Value $Configuration.RoleMembers $RoleValue @())
        @(Get-Value $Configuration.RoleMembers "$AppKey/$RoleValue" @())
    ) | Where-Object { $_ }
}

function Sync-RoleAssignments {
    <#
    .SYNOPSIS
        Phase 3 for one application: assignments match the environment file plus the own applications
        that request a role. Assignments not listed are removed; the file is the source of truth.
    #>
    param($Synced, [hashtable] $All, $Configuration, [switch] $AllowUnresolvedPrincipals)
    $definition = $Synced.Definition
    $roles = @(Get-Value $definition 'appRoles' @())
    if ($roles.Count -eq 0) { return }

    $servicePrincipal = $Synced.ServicePrincipal
    $displayName = $Synced.Application.displayName
    $existing = if (Test-Placeholder $servicePrincipal.id) { @() } else { @(Invoke-Graph -Uri "/servicePrincipals/$($servicePrincipal.id)/appRoleAssignedTo" -All) }
    $spRoles = @(Get-Value $servicePrincipal 'appRoles' @())

    foreach ($role in $roles) {
        $value = Get-Value $role 'value'
        $allowed = @(Get-Value $role 'allowedMemberTypes' @())
        $roleId = $spRoles | Where-Object value -EQ $value | ForEach-Object { $_.id } | Select-Object -First 1
        if (-not $roleId) { $roleId = "new:$value" }

        $desired = [Collections.Generic.List[object]]::new()
        foreach ($member in (Resolve-RoleMembers -Names (Get-RoleMemberNames $Configuration $Synced.Key $value) -AllowUnresolved:$AllowUnresolvedPrincipals)) {
            $needed = if ($member.Type -eq 'ServicePrincipal') { 'Application' } else { 'User' }
            if ($needed -notin $allowed) {
                if ($member.ViaGroup) { continue }
                throw "$displayName`: role '$value' does not allow $($needed.ToLower())s, but '$($member.Name)' ($($member.Type)) is listed as a member."
            }
            $desired.Add($member)
        }

        foreach ($client in $All.Values) {
            foreach ($access in @(Get-Value $client.Definition 'requiredResourceAccess' @())) {
                if ((Get-Value $access 'resource') -eq $Synced.Key -and $value -in @(Get-Value $access 'roles' @())) {
                    $desired.Add([pscustomobject]@{ Id = $client.ServicePrincipal.id; Type = 'ServicePrincipal'; Name = $client.Application.displayName; DisplayName = $client.Application.displayName })
                }
            }
        }

        $current = @($existing | Where-Object { $_.appRoleId -eq $roleId })
        # ForEach-Object instead of member enumeration: StrictMode throws on an empty collection.
        $currentIds = @($current | ForEach-Object { $_.principalId })
        $desiredIds = @($desired | ForEach-Object { $_.Id })
        foreach ($member in @($desired | Sort-Object Id -Unique)) {
            if ($member.Id -in $currentIds) { continue }
            Invoke-Change -Target $displayName -Action "assign role '$value' to $($member.DisplayName)" -Script {
                Invoke-Graph -Method POST -Uri "/servicePrincipals/$($servicePrincipal.id)/appRoleAssignedTo" -Body @{
                    principalId = $member.Id; resourceId = $servicePrincipal.id; appRoleId = $roleId
                } | Out-Null
            } | Out-Null
        }

        foreach ($assignment in @($current | Where-Object { $_.principalId -notin $desiredIds })) {
            Invoke-Change -Target $displayName -Action "remove role '$value' from $($assignment.principalDisplayName)" -Script {
                Invoke-Graph -Method DELETE -Uri "/servicePrincipals/$($servicePrincipal.id)/appRoleAssignedTo/$($assignment.id)" | Out-Null
            } | Out-Null
        }
    }
}

#endregion

#region Run

function Invoke-AppRegistrationSync {
    <#
    .SYNOPSIS
        Makes Entra ID match the configuration of one environment. Returns the changes.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] $Configuration,
        [switch] $DryRun,
        [switch] $AllowUnresolvedPrincipals
    )

    Initialize-RunState -DryRun:$DryRun
    $problems = @(Test-AppRegistrationConfiguration -Configuration $Configuration)
    if ($problems.Count -gt 0) {
        throw "The configuration of '$($Configuration.Name)' is invalid:`n  $($problems -join "`n  ")"
    }

    $ownerIds = @()
    if ($Configuration.ManageOwners) {
        $ownerIds = @(@(Resolve-Owners -Names $Configuration.Owners -AllowUnresolved:$AllowUnresolvedPrincipals | ForEach-Object { $_.Id }) + (Get-CurrentIdentityId) | Sort-Object -Unique)
    }

    $synced = [ordered]@{}
    foreach ($definition in $Configuration.Applications) {
        $result = Sync-Application -Definition $definition -Configuration $Configuration -OwnerIds $ownerIds
        $synced[$result.Key] = $result
    }

    $all = @{} + $synced
    foreach ($entry in $synced.Values) { Sync-Permissions -Synced $entry -All $all }

    if ($Configuration.ManageRoleAssignments) {
        foreach ($entry in $synced.Values) { Sync-RoleAssignments -Synced $entry -All $all -Configuration $Configuration -AllowUnresolvedPrincipals:$AllowUnresolvedPrincipals }
    }

    $script:Changes.ToArray()
}

#endregion

#region Consent

function Get-ConsentStatus {
    <#
    .SYNOPSIS
        Compares the permissions each application requests with what is actually granted.
    .DESCRIPTION
        Application permissions are granted by app role assignments; delegated permissions by an
        admin consent grant for all users, or by the resource pre-authorizing the client.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)] $Configuration)

    Initialize-RunState
    $rows = [Collections.Generic.List[object]]::new()
    $apps = @{}
    foreach ($definition in $Configuration.Applications) {
        $key = Get-Value $definition 'key'
        $displayName = Get-Value $definition 'displayName'
        $application = @(Invoke-Graph -Uri (New-FilterUri '/applications' "displayName eq $(ConvertTo-ODataString $displayName)") -All) | Select-Object -First 1
        $servicePrincipal = if ($application) { @(Invoke-Graph -Uri (New-FilterUri '/servicePrincipals' "appId eq $(ConvertTo-ODataString $application.appId)") -All) | Select-Object -First 1 }
        $apps[$key] = [pscustomobject]@{ Key = $key; Definition = $definition; Application = $application; ServicePrincipal = $servicePrincipal }
    }

    $templates = @{}
    foreach ($t in $Configuration.Templates) { $templates[(Get-Value $t 'key')] = $t }

    foreach ($app in $apps.Values) {
        $accessList = @(Get-Value $app.Definition 'requiredResourceAccess' @())
        $templateAccess = @(Get-Value $templates[$app.Key] 'requiredResourceAccess' @())
        $base = @{ App = (Get-Value $app.Definition 'displayName'); AppKey = $app.Key; AppId = if ($app.Application) { $app.Application.appId } else { $null } }

        if (-not $app.ServicePrincipal) {
            $rows.Add([pscustomobject](@{ Resource = '-'; Permission = '-'; Type = '-'; Status = 'AppNotFound'; Template = "$($app.Key)|-|-|-" } + $base))
            continue
        }

        $grantedRoles = @(Invoke-Graph -Uri "/servicePrincipals/$($app.ServicePrincipal.id)/appRoleAssignments" -All)
        $grantedScopes = @(Invoke-Graph -Uri (New-FilterUri '/oauth2PermissionGrants' "clientId eq $(ConvertTo-ODataString $app.ServicePrincipal.id) and consentType eq 'AllPrincipals'") -All)

        for ($i = 0; $i -lt $accessList.Count; $i++) {
            $access = $accessList[$i]
            $resourceName = Get-Value $access 'resource'
            $resourceTemplate = if ($i -lt $templateAccess.Count) { Get-Value $templateAccess[$i] 'resource' $resourceName } else { $resourceName }
            $permissions = @(@(Get-Value $access 'scopes' @() | ForEach-Object { @{ Value = $_; Type = 'Delegated' } }) + @(Get-Value $access 'roles' @() | ForEach-Object { @{ Value = $_; Type = 'Application' } }))

            $target = $null
            $targetSpId = $null
            try {
                if ($apps.ContainsKey($resourceName)) {
                    $target = $apps[$resourceName]
                    $targetSpId = if ($target.ServicePrincipal) { $target.ServicePrincipal.id } else { $null }
                    $resource = if ($target.Application) { Resolve-Resource -Resource $resourceName -Synced @{ $resourceName = $target } } else { $null }
                }
                else {
                    $resource = Resolve-Resource -Resource $resourceName
                    $targetSpId = $resource.ServicePrincipal.id
                }
            }
            catch { $resource = $null }

            foreach ($permission in $permissions) {
                $row = @{ Resource = $resourceName; Permission = $permission.Value; Type = $permission.Type; Template = "$($app.Key)|$resourceTemplate|$($permission.Value)|$($permission.Type)" } + $base
                $row.Status = if (-not $resource -or -not $targetSpId) { 'ResourceNotFound' }
                elseif ($permission.Type -eq 'Application') {
                    $roleId = if ($resource.Roles.ContainsKey($permission.Value)) { $resource.Roles[$permission.Value].Id } else { $null }
                    if (-not $roleId) { 'PermissionNotFound' }
                    elseif (@($grantedRoles | Where-Object { $_.resourceId -eq $targetSpId -and $_.appRoleId -eq $roleId }).Count) { 'Granted' }
                    else { 'Missing' }
                }
                else {
                    $scopeId = if ($resource.Scopes.ContainsKey($permission.Value)) { $resource.Scopes[$permission.Value] } else { $null }
                    $preAuthorized = $target -and $target.Application -and @(@(Get-Value $target.Application.api 'preAuthorizedApplications' @()) |
                            Where-Object { $_.appId -eq $app.Application.appId -and $scopeId -in @($_.delegatedPermissionIds) }).Count
                    if (-not $scopeId) { 'PermissionNotFound' }
                    elseif ($preAuthorized) { 'PreAuthorized' }
                    elseif (@($grantedScopes | Where-Object { $_.resourceId -eq $targetSpId -and $permission.Value -in ($_.scope -split ' ') }).Count) { 'Granted' }
                    else { 'Missing' }
                }
                $rows.Add([pscustomobject]$row)
            }
        }
    }

    $rows | Sort-Object App, Resource, Permission
}

function Compare-ConsentStatus {
    <# Differences between two environments' consent status, matched on the definition, not on names. #>
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]] $Reference,
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]] $Difference,
        [string] $ReferenceName = 'reference',
        [string] $DifferenceName = 'difference',
        [switch] $IncludeEqual
    )
    $left = @{}; foreach ($r in $Reference) { $left[$r.Template] = $r }
    $right = @{}; foreach ($r in $Difference) { $right[$r.Template] = $r }
    $rows = foreach ($key in @(@($left.Keys) + @($right.Keys) | Sort-Object -Unique)) {
        $l = $left[$key]; $r = $right[$key]
        $statusLeft = if ($l) { $l.Status } else { '(absent)' }
        $statusRight = if ($r) { $r.Status } else { '(absent)' }
        if (-not $IncludeEqual -and $statusLeft -eq $statusRight) { continue }
        $any = if ($l) { $l } else { $r }
        [pscustomobject]@{ AppKey = $any.AppKey; Resource = $key.Split('|')[1]; Permission = $any.Permission; Type = $any.Type; $ReferenceName = $statusLeft; $DifferenceName = $statusRight }
    }
    $rows
}

#endregion
