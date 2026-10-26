#Requires -Version 7.2
<#
.SYNOPSIS
    Shows, per application, which requested permissions are granted and which still need consent.

.DESCRIPTION
    Status per permission:
      Granted             application permission assigned, or delegated permission consented for all users
      PreAuthorized       delegated permission on an own API that pre-authorizes this client
      Missing             requested, not granted: an administrator must consent
      AppNotFound         the application does not exist yet in this environment
      ResourceNotFound    the requested API does not exist (yet) in this tenant
      PermissionNotFound  the API exists but does not offer this role or scope

.EXAMPLE
    ./Get-ConsentStatus.ps1 -Environment test
.EXAMPLE
    ./Get-ConsentStatus.ps1 -Environment prod -OnlyMissing
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string] $Environment,
    [string] $DefinitionPath = (Join-Path $PSScriptRoot 'app-registrations.json'),
    [switch] $OnlyMissing,
    [switch] $PassThru
)

$ErrorActionPreference = 'Stop'
$InformationPreference = 'Continue'
. (Join-Path $PSScriptRoot 'lib/AppRegistrations.ps1')

$environmentPath = if (Test-Path -LiteralPath $Environment -PathType Leaf) { $Environment } else { Join-Path $PSScriptRoot "environments/$Environment.json" }
$account = Invoke-AzCli -Arguments @('account', 'show')
$configuration = Read-AppRegistrationConfiguration -DefinitionPath $DefinitionPath -EnvironmentPath $environmentPath
$rows = @(Get-ConsentStatus -Configuration $configuration)

$shown = if ($OnlyMissing) { @($rows | Where-Object Status -NotIn 'Granted', 'PreAuthorized') } else { $rows }
if ($shown.Count -gt 0) {
    $shown | Format-Table App, Resource, Permission, Type, Status -AutoSize | Out-String -Width 200 | Write-Information
}

$counts = $rows | Group-Object Status | ForEach-Object { "$($_.Name): $($_.Count)" }
Write-Information "Consent status for '$($configuration.Name)': $($counts -join ', ')"

$missing = @($rows | Where-Object Status -EQ 'Missing')
if ($missing.Count -gt 0) {
    Write-Information ''
    Write-Information 'Ask an administrator to grant admin consent for:'
    foreach ($group in ($missing | Group-Object App)) {
        $appId = $group.Group[0].AppId
        Write-Information "  $($group.Name) ($appId)"
        $group.Group | ForEach-Object { Write-Information "    - $($_.Permission) ($($_.Type)) on $($_.Resource)" }
        Write-Information "    https://login.microsoftonline.com/$($account.tenantId)/adminconsent?client_id=$appId"
    }
}

if ($PassThru) { $rows }
