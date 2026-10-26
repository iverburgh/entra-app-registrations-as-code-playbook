#Requires -Version 7.2
<#
.SYNOPSIS
    Shows where two environments differ in which permissions are granted.

.DESCRIPTION
    Typical use: before promoting a release, check that production has every consent the test
    environment has. Permissions are matched on the definition (application key, resource and
    value), so differently named applications in each environment still line up.

.EXAMPLE
    ./Compare-ConsentStatus.ps1 -Reference test -Difference prod
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string] $Reference,
    [Parameter(Mandatory)][string] $Difference,
    [string] $DefinitionPath = (Join-Path $PSScriptRoot 'app-registrations.json'),
    [switch] $IncludeEqual,
    [switch] $PassThru
)

$ErrorActionPreference = 'Stop'
$InformationPreference = 'Continue'
. (Join-Path $PSScriptRoot 'lib/AppRegistrations.ps1')

function Get-Rows([string] $Name) {
    $path = if (Test-Path -LiteralPath $Name -PathType Leaf) { $Name } else { Join-Path $PSScriptRoot "environments/$Name.json" }
    @(Get-ConsentStatus -Configuration (Read-AppRegistrationConfiguration -DefinitionPath $DefinitionPath -EnvironmentPath $path))
}

$rows = @(Compare-ConsentStatus -Reference @(Get-Rows $Reference) -Difference @(Get-Rows $Difference) -ReferenceName $Reference -DifferenceName $Difference -IncludeEqual:$IncludeEqual)

if ($rows.Count -eq 0) {
    Write-Information "No differences in consent status between '$Reference' and '$Difference'."
}
else {
    $rows | Format-Table -AutoSize | Out-String -Width 200 | Write-Information
}

if ($PassThru) { $rows }
