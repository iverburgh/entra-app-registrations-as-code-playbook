#Requires -Version 7.2
<#
.SYNOPSIS
    Runs Invoke-AppRegistrations.ps1 for every environment, lowest first.

.DESCRIPTION
    Environments are taken from environments/*.json, ordered by their "order" property and then by
    name. The run stops at the first environment that fails, so a mistake surfaces in a test
    environment before it reaches production.

.PARAMETER Environment
    Run only these environments, in this order.

.EXAMPLE
    ./Invoke-AllAppRegistrations.ps1 -WhatIf
.EXAMPLE
    ./Invoke-AllAppRegistrations.ps1 -Environment dev, test
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [string[]] $Environment,
    [switch] $AllowUnresolvedPrincipals,
    [switch] $ContinueOnError
)

$ErrorActionPreference = 'Stop'
$InformationPreference = 'Continue'

$names = if ($Environment) { $Environment } else {
    Get-ChildItem -Path (Join-Path $PSScriptRoot 'environments') -Filter '*.json' |
        ForEach-Object {
            $order = (Get-Content -LiteralPath $_.FullName -Raw | ConvertFrom-Json -AsHashtable)['order']
            [pscustomobject]@{ Name = $_.BaseName; Order = if ($null -ne $order) { [int]$order } else { 100 } }
        } |
        Sort-Object Order, Name |
        ForEach-Object Name
}

$failed = @()
foreach ($name in $names) {
    Write-Information ''
    Write-Information "=== $name ==="
    try {
        & (Join-Path $PSScriptRoot 'Invoke-AppRegistrations.ps1') -Environment $name -AllowUnresolvedPrincipals:$AllowUnresolvedPrincipals -WhatIf:$WhatIfPreference
    }
    catch {
        $failed += $name
        Write-Error "Environment '$name' failed: $_" -ErrorAction Continue
        if (-not $ContinueOnError) { break }
    }
}

if ($failed.Count -gt 0) {
    throw "Failed: $($failed -join ', ')."
}
