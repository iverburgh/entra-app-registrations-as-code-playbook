<#
.SYNOPSIS
    Shared set-up: a small system of three applications, and a tenant with the people, groups and
    services its environment file refers to.
#>

$script:Definition = @{
    appRegistrations = @(
        @{
            key                       = 'orders-api'
            displayName               = 'orders-api-#{environment}#'
            credential                = @{ type = 'certificate'; keyVault = 'kv-orders-#{environment}#'; tags = @{ owner = 'orders-team' } }
            appRoles                  = @(
                @{ value = 'Orders.Read'; displayName = 'Order reader'; description = 'Read orders.'; allowedMemberTypes = @('User', 'Application') }
                @{ value = 'Orders.Admin'; displayName = 'Order administrator'; description = 'Change orders.'; allowedMemberTypes = @('User') }
                @{ value = 'Orders.Process'; displayName = 'Order processor'; description = 'Process orders.'; allowedMemberTypes = @('Application') }
            )
            scopes                    = @(
                @{ value = 'access_as_user'; adminConsentDisplayName = 'Access the orders API'; adminConsentDescription = 'Call the orders API as the user.' }
            )
            preAuthorizedApplications = @(
                @{ application = 'orders-web'; scopes = @('access_as_user') }
                @{ application = 'azure-cli'; scopes = @('access_as_user') }
            )
            requiredResourceAccess    = @(@{ resource = 'microsoft-graph'; scopes = @('User.Read') })
        }
        @{
            key                    = 'orders-web'
            displayName            = 'orders-web-#{environment}#'
            appRoles               = @(
                @{ value = 'Orders.Read'; displayName = 'Order reader'; description = 'See the order screens.'; allowedMemberTypes = @('User') }
            )
            redirectUris           = @{ spa = 'orders-web' }
            requiredResourceAccess = @(
                @{ resource = 'microsoft-graph'; scopes = @('User.Read') }
                @{ resource = 'orders-api'; scopes = @('access_as_user') }
            )
        }
        @{
            key                    = 'orders-worker'
            displayName            = 'orders-worker-#{environment}#'
            credential             = @{ type = 'secret'; name = 'pipeline'; keyVault = 'kv-orders-#{environment}#' }
            requiredResourceAccess = @(
                @{ resource = 'orders-api'; roles = @('Orders.Process') }
                @{ resource = 'invoices-api-#{environment}#'; roles = @('Invoices.Create') }
            )
        }
    )
}

function New-TestEnvironment([string] $Name = 'dev') {
    @{
        name         = $Name
        tokens       = @{ environment = $Name }
        owners       = @('orders-owners')
        roleMembers  = @{
            'Orders.Read'    = @('orders-readers', 'user:tester@example.com')
            'Orders.Process' = @('sp:id-orders-processor')
        }
        redirectUris = @{ 'orders-web' = @('http://localhost:5173/', "https://orders-$Name.example.com/") }
    }
}

function Read-TestConfiguration {
    param([hashtable] $Definition = $script:Definition, [hashtable] $Environment = (New-TestEnvironment))
    $definitionPath = Join-Path $TestDrive 'app-registrations.json'
    $environmentPath = Join-Path $TestDrive "$($Environment.name).json"
    ConvertTo-Json $Definition -Depth 20 | Set-Content -LiteralPath $definitionPath
    ConvertTo-Json $Environment -Depth 20 | Set-Content -LiteralPath $environmentPath
    Read-AppRegistrationConfiguration -DefinitionPath $definitionPath -EnvironmentPath $environmentPath
}

function Initialize-TestTenant([string[]] $Environments = @('dev')) {
    New-FakeDirectory
    $global:Ids = @{}
    $global:Ids.Owner1 = Add-FakeUser 'owner1@example.com' 'Owner One'
    $global:Ids.Owner2 = Add-FakeUser 'owner2@example.com' 'Owner Two'
    $nested = Add-FakeGroup 'orders-owners-nested' @($global:Ids.Owner2)
    $global:Ids.Owners = Add-FakeGroup 'orders-owners' @($global:Ids.Owner1, $nested)
    $global:Ids.Reader = Add-FakeUser 'reader@example.com' 'Reader'
    $global:Ids.Tester = Add-FakeUser 'tester@example.com' 'Tester'
    $global:Ids.ReaderJob = Add-FakeServicePrincipal -DisplayName 'id-reader-job'
    $global:Ids.Readers = Add-FakeGroup 'orders-readers' @($global:Ids.Reader, $global:Ids.ReaderJob)
    $global:Ids.Processor = Add-FakeServicePrincipal -DisplayName 'id-orders-processor'
    $global:Ids.Graph = Add-FakeServicePrincipal -DisplayName 'Microsoft Graph' -AppId '00000003-0000-0000-c000-000000000000' -Scopes @(@{ value = 'User.Read' })
    foreach ($environment in $Environments) {
        $global:Ids["Invoices-$environment"] = Add-FakeServicePrincipal -DisplayName "invoices-api-$environment" -AppRoles @(@{ value = 'Invoices.Create' })
    }
}

function Get-TestApplication([string] $DisplayName) {
    $global:Fake.Applications.Values | Where-Object displayName -EQ $DisplayName | Select-Object -First 1
}

function Get-TestServicePrincipal([string] $DisplayName) {
    $application = Get-TestApplication $DisplayName
    $global:Fake.ServicePrincipals.Values | Where-Object appId -EQ $application.appId | Select-Object -First 1
}

function Get-TestAssignments([string] $DisplayName, [string] $RoleValue) {
    $sp = Get-FakeServicePrincipal (Get-TestServicePrincipal $DisplayName).id
    $roleId = ($sp.appRoles | Where-Object value -EQ $RoleValue).id
    @($global:Fake.Assignments | Where-Object { $_.resourceId -eq $sp.id -and $_.appRoleId -eq $roleId } | ForEach-Object principalId)
}
