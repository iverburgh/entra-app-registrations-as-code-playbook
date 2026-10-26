BeforeAll {
    . "$PSScriptRoot/../lib/AppRegistrations.ps1"
    . "$PSScriptRoot/FakeDirectory.ps1"
    . "$PSScriptRoot/TestSystem.ps1"
    # $PSBoundParameters is empty inside a mock body, so the parameters are passed on by name.
    Mock Invoke-Graph { Invoke-FakeGraph -Method $Method -Uri $Uri -Body $Body -All:$All -AllowNotFound:$AllowNotFound }
    Mock Invoke-AzCli { Invoke-FakeAzCli -Arguments $Arguments -AllowFailure:$AllowFailure }

    function Get-Status($Rows, [string] $AppKey, [string] $Permission) {
        @($Rows | Where-Object { $_.AppKey -eq $AppKey -and $_.Permission -eq $Permission } | ForEach-Object { $_.Status })
    }

    function Grant-AdminConsent([string] $ClientDisplayName, [string] $ResourceId, [string] $Scope) {
        $global:Fake.Grants.Add([pscustomobject]@{
                id          = New-FakeId
                clientId    = (Get-TestServicePrincipal $ClientDisplayName).id
                consentType = 'AllPrincipals'
                resourceId  = $ResourceId
                scope       = $Scope
            })
    }
}

Describe 'The consent status of an environment' {
    BeforeEach {
        Initialize-TestTenant
        Invoke-AppRegistrationSync -Configuration (Read-TestConfiguration) | Out-Null
    }

    It 'reports a delegated permission on an own API that pre-authorizes the client as pre-authorized' {
        $rows = @(Get-ConsentStatus -Configuration (Read-TestConfiguration))
        Get-Status $rows 'orders-web' 'access_as_user' | Should -Be 'PreAuthorized'
    }

    It 'reports a delegated permission on another API as missing until an administrator consents' {
        Get-Status @(Get-ConsentStatus -Configuration (Read-TestConfiguration)) 'orders-web' 'User.Read' | Should -Be 'Missing'

        Grant-AdminConsent 'orders-web-dev' $global:Ids.Graph 'openid User.Read'

        Get-Status @(Get-ConsentStatus -Configuration (Read-TestConfiguration)) 'orders-web' 'User.Read' | Should -Be 'Granted'
    }

    It 'reports an application permission on an own API as granted, as the sync assigns it' {
        Get-Status @(Get-ConsentStatus -Configuration (Read-TestConfiguration)) 'orders-worker' 'Orders.Process' | Should -Be 'Granted'
    }

    It 'reports an application permission on another API as missing' {
        Get-Status @(Get-ConsentStatus -Configuration (Read-TestConfiguration)) 'orders-worker' 'Invoices.Create' | Should -Be 'Missing'
    }

    It 'reports an API that is gone, and a permission the API does not offer' {
        $global:Fake.ServicePrincipals.Remove($global:Ids['Invoices-dev'])
        Get-Status @(Get-ConsentStatus -Configuration (Read-TestConfiguration)) 'orders-worker' 'Invoices.Create' | Should -Be 'ResourceNotFound'

        $changed = Copy-AsHashtable $script:Definition
        $changed.appRegistrations[1].requiredResourceAccess[0].scopes = @('Mail.Send')
        Get-Status @(Get-ConsentStatus -Configuration (Read-TestConfiguration -Definition $changed)) 'orders-web' 'Mail.Send' | Should -Be 'PermissionNotFound'
    }

    It 'changes nothing in the tenant' {
        $writes = $global:Fake.Writes.Count
        Get-ConsentStatus -Configuration (Read-TestConfiguration) | Out-Null
        $global:Fake.Writes.Count | Should -Be $writes
    }
}

Describe 'The consent status before the first run' {
    It 'reports every application as not found' {
        Initialize-TestTenant
        $rows = @(Get-ConsentStatus -Configuration (Read-TestConfiguration))
        $rows | Should -HaveCount 3
        $rows.Status | Sort-Object -Unique | Should -Be 'AppNotFound'
    }
}

Describe 'Comparing the consent status of two environments' {
    BeforeAll {
        Initialize-TestTenant -Environments 'dev', 'test'
        Invoke-AppRegistrationSync -Configuration (Read-TestConfiguration -Environment (New-TestEnvironment 'dev')) | Out-Null
        Invoke-AppRegistrationSync -Configuration (Read-TestConfiguration -Environment (New-TestEnvironment 'test')) | Out-Null
        Grant-AdminConsent 'orders-web-dev' $global:Ids.Graph 'User.Read'
        $script:Dev = @(Get-ConsentStatus -Configuration (Read-TestConfiguration -Environment (New-TestEnvironment 'dev')))
        $script:Test = @(Get-ConsentStatus -Configuration (Read-TestConfiguration -Environment (New-TestEnvironment 'test')))
    }

    It 'shows only the permissions whose status differs' {
        $differences = @(Compare-ConsentStatus -Reference $Dev -Difference $Test -ReferenceName dev -DifferenceName test)
        $differences | Should -HaveCount 1
        $differences[0].AppKey | Should -Be 'orders-web'
        $differences[0].Permission | Should -Be 'User.Read'
        $differences[0].dev | Should -Be 'Granted'
        $differences[0].test | Should -Be 'Missing'
    }

    It 'lines up permissions on APIs whose names differ per environment' {
        $all = @(Compare-ConsentStatus -Reference $Dev -Difference $Test -ReferenceName dev -DifferenceName test -IncludeEqual)
        $all | Should -HaveCount $Dev.Count
        $invoices = $all | Where-Object Permission -EQ 'Invoices.Create'
        $invoices.Resource | Should -Be 'invoices-api-#{environment}#'
        $invoices.dev | Should -Be $invoices.test
    }
}
