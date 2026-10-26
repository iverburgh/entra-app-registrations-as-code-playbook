#Requires -Version 7.2
<#
.SYNOPSIS
    Makes the app registrations of one environment match the configuration.

.DESCRIPTION
    Reads app-registrations.json and environments/<Environment>.json, and creates or updates the
    applications, service principals, roles, scopes, redirect URIs, credentials, owners, requested
    permissions, pre-authorized clients and role assignments. Running it twice changes nothing the
    second time.

    Use -WhatIf first: it shows every change without making one.

.PARAMETER Environment
    The name of a file in environments/ (without .json), or a path to an environment file.

.PARAMETER AllowUnresolvedPrincipals
    Skip owners and role members that cannot be found, instead of stopping. Careful: a misspelled
    name then removes the access that name had.

.PARAMETER PassThru
    Return the changes as objects.

.EXAMPLE
    ./Invoke-AppRegistrations.ps1 -Environment dev -WhatIf
.EXAMPLE
    ./Invoke-AppRegistrations.ps1 -Environment dev
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)]
    [string] $Environment,
    [string] $DefinitionPath = (Join-Path $PSScriptRoot 'app-registrations.json'),
    [switch] $AllowUnresolvedPrincipals,
    [switch] $PassThru
)

$ErrorActionPreference = 'Stop'
$InformationPreference = 'Continue'
. (Join-Path $PSScriptRoot 'lib/AppRegistrations.ps1')

$environmentPath = if (Test-Path -LiteralPath $Environment -PathType Leaf) { $Environment } else { Join-Path $PSScriptRoot "environments/$Environment.json" }
if (-not (Test-Path -LiteralPath $environmentPath -PathType Leaf)) {
    throw "Environment file '$environmentPath' not found."
}

$account = Invoke-AzCli -Arguments @('account', 'show') -AllowFailure
if (-not $account) {
    throw 'The Azure CLI is not signed in. Run az login (locally) or use an Azure CLI task with a service connection (in a pipeline).'
}

$configuration = Read-AppRegistrationConfiguration -DefinitionPath $DefinitionPath -EnvironmentPath $environmentPath
$mode = if ($WhatIfPreference) { 'Planning' } else { 'Applying' }
Write-Information "$mode app registrations for '$($configuration.Name)' in tenant $($account.tenantId) as $($account.user.name)"

$changes = @(Invoke-AppRegistrationSync -Configuration $configuration -DryRun:$WhatIfPreference -AllowUnresolvedPrincipals:$AllowUnresolvedPrincipals)

Write-Information ''
if ($changes.Count -eq 0) {
    Write-Information "No changes: Entra ID matches the configuration of '$($configuration.Name)'."
}
else {
    $verb = if ($WhatIfPreference) { 'planned' } else { 'made' }
    Write-Information "$($changes.Count) change(s) $verb for '$($configuration.Name)':"
    $changes | Format-Table -AutoSize -Wrap | Out-String -Width 200 | Write-Information
}

if ($PassThru) { $changes }
