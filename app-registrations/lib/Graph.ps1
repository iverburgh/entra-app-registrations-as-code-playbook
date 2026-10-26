#Requires -Version 7.2
<#
.SYNOPSIS
    The only two functions that talk to Azure. Everything else calls these, so tests replace them
    with an in-memory directory.
#>

Set-StrictMode -Version Latest

$script:GraphBaseUrl = 'https://graph.microsoft.com/v1.0'

function Invoke-Graph {
    <#
    .SYNOPSIS
        Calls Microsoft Graph through `az rest`, with the signed-in Azure CLI identity.
    .PARAMETER Uri
        Relative to https://graph.microsoft.com/v1.0 (for example '/applications'), or absolute.
    .PARAMETER All
        Follow @odata.nextLink and write every item of a collection to the pipeline. Wrap the call in @().
    .PARAMETER AllowNotFound
        Return $null on 404 instead of throwing.
    #>
    [CmdletBinding()]
    param(
        [ValidateSet('GET', 'POST', 'PATCH', 'DELETE')]
        [string] $Method = 'GET',
        [Parameter(Mandatory)]
        [string] $Uri,
        [object] $Body,
        [switch] $All,
        [switch] $AllowNotFound
    )

    $url = if ($Uri -match '^https://') { $Uri } else { "$script:GraphBaseUrl$Uri" }
    $items = [Collections.Generic.List[object]]::new()
    do {
        $arguments = @('rest', '--method', $Method, '--uri', $url, '--only-show-errors')
        $bodyFile = $null
        if ($null -ne $Body) {
            # A file avoids every quoting difference between shells.
            $bodyFile = New-TemporaryFile
            ConvertTo-Json -InputObject $Body -Depth 20 -Compress | Set-Content -LiteralPath $bodyFile -Encoding utf8NoBOM
            $arguments += @('--headers', 'Content-Type=application/json', '--body', "@$bodyFile")
        }

        try {
            $output = & az @arguments 2>&1
            $exitCode = $LASTEXITCODE
        }
        finally {
            if ($bodyFile) { Remove-Item -LiteralPath $bodyFile -Force -ErrorAction SilentlyContinue }
        }

        $text = ($output | ForEach-Object { "$_" }) -join "`n"
        if ($exitCode -ne 0) {
            if ($AllowNotFound -and $text -match 'Not Found|ResourceNotFound|does not exist') {
                return $null
            }
            throw "Microsoft Graph $Method $url failed: $text"
        }

        $response = if ([string]::IsNullOrWhiteSpace($text)) { $null } else { $text | ConvertFrom-Json -Depth 50 }
        if (-not $All) {
            return $response
        }

        foreach ($item in @($response.value)) { $items.Add($item) }
        $url = if ($response.PSObject.Properties['@odata.nextLink']) { $response.'@odata.nextLink' } else { $null }
    } while ($url)

    # Emitted one by one: callers wrap the call in @(), which then holds exactly the items.
    $items.ToArray()
}

function Invoke-AzCli {
    <#
    .SYNOPSIS
        Runs an Azure CLI command and returns its JSON output as objects.
    .PARAMETER AllowFailure
        Return $null when the command fails (for example: show something that does not exist).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string[]] $Arguments,
        [switch] $AllowFailure
    )

    $output = & az @Arguments --only-show-errors --output json 2>&1
    $exitCode = $LASTEXITCODE
    $text = ($output | ForEach-Object { "$_" }) -join "`n"
    if ($exitCode -ne 0) {
        if ($AllowFailure) { return $null }
        throw "az $($Arguments[0..1] -join ' ') failed: $text"
    }

    if ([string]::IsNullOrWhiteSpace($text)) { return $null }
    return $text | ConvertFrom-Json -Depth 50
}

function ConvertTo-ODataString {
    <# Quotes a value for use inside an OData $filter. #>
    param([Parameter(Mandatory)][AllowEmptyString()][string] $Value)
    "'" + $Value.Replace("'", "''") + "'"
}
