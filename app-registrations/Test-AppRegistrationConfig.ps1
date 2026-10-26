#Requires -Version 7.2
<#
.SYNOPSIS
    Validates the definitions and every environment file, without contacting Entra ID.

.DESCRIPTION
    Checks both files against their JSON schema, fills in each environment's tokens, and checks
    the references between them: requested roles and scopes that exist, redirect URI lists that
    are defined, role members for roles that exist. Runs anywhere, including pull request builds
    without access to the tenant.

.EXAMPLE
    ./Test-AppRegistrationConfig.ps1
#>
[CmdletBinding()]
param(
    [string] $DefinitionPath = (Join-Path $PSScriptRoot 'app-registrations.json'),
    [string] $EnvironmentFolder = (Join-Path $PSScriptRoot 'environments')
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'lib/AppRegistrations.ps1')

$schemas = Join-Path $PSScriptRoot 'schemas'
$problems = [Collections.Generic.List[string]]::new()

function Test-AgainstSchema([string] $Path, [string] $Schema) {
    try {
        if (-not (Test-Json -Json (Get-Content -LiteralPath $Path -Raw) -SchemaFile $Schema -ErrorAction Stop)) {
            $problems.Add("$(Split-Path -Leaf $Path): does not match $(Split-Path -Leaf $Schema).")
        }
    }
    catch {
        $problems.Add("$(Split-Path -Leaf $Path): $($_.Exception.Message)")
    }
}

Test-AgainstSchema $DefinitionPath (Join-Path $schemas 'app-registrations.schema.json')

$environments = @(Get-ChildItem -Path $EnvironmentFolder -Filter '*.json')
if ($environments.Count -eq 0) {
    $problems.Add("No environment files in $EnvironmentFolder.")
}

foreach ($file in $environments) {
    Test-AgainstSchema $file.FullName (Join-Path $schemas 'environment.schema.json')
    try {
        $configuration = Read-AppRegistrationConfiguration -DefinitionPath $DefinitionPath -EnvironmentPath $file.FullName
        foreach ($problem in (Test-AppRegistrationConfiguration -Configuration $configuration)) { $problems.Add($problem) }
    }
    catch {
        $problems.Add("$($file.Name): $($_.Exception.Message)")
    }
}

if ($problems.Count -eq 0) {
    Write-Host "Configuration is valid: $(Split-Path -Leaf $DefinitionPath) with $($environments.Count) environment(s)." -ForegroundColor Green
    exit 0
}

Write-Host "$($problems.Count) problem(s):" -ForegroundColor Red
$problems | ForEach-Object { Write-Host "  $_" }
exit 1
