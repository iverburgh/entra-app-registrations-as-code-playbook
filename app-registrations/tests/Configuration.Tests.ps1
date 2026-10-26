BeforeAll {
    . "$PSScriptRoot/../lib/AppRegistrations.ps1"
    . "$PSScriptRoot/FakeDirectory.ps1"
    . "$PSScriptRoot/TestSystem.ps1"

    $script:Root = Split-Path -Parent $PSScriptRoot

    function Get-Problems([hashtable] $Definition = $script:Definition, [hashtable] $Environment = (New-TestEnvironment)) {
        @(Test-AppRegistrationConfiguration -Configuration (Read-TestConfiguration -Definition $Definition -Environment $Environment))
    }
}

Describe 'Reading a configuration' {
    It 'fills in the tokens of the environment, and keeps the definition as written for comparisons' {
        $configuration = Read-TestConfiguration -Environment (New-TestEnvironment 'test')
        $configuration.Name | Should -Be 'test'
        $configuration.Applications[0].displayName | Should -Be 'orders-api-test'
        $configuration.Templates[0].displayName | Should -Be 'orders-api-#{environment}#'
    }

    It 'stops on a token the environment does not define' {
        $changed = Copy-AsHashtable $script:Definition
        $changed.appRegistrations[0].displayName = 'orders-api-#{region}#'
        { Read-TestConfiguration -Definition $changed } | Should -Throw '*region*'
    }

    It 'manages owners and role assignments unless the environment says otherwise' {
        $configuration = Read-TestConfiguration
        $configuration.ManageOwners | Should -BeTrue
        $configuration.ManageRoleAssignments | Should -BeTrue

        $environment = New-TestEnvironment
        $environment.manageOwners = $false
        (Read-TestConfiguration -Environment $environment).ManageOwners | Should -BeFalse
    }
}

Describe 'The example configuration' {
    BeforeDiscovery {
        $script:Environments = @(Get-ChildItem -Path (Join-Path (Split-Path -Parent $PSScriptRoot) 'environments') -Filter '*.json' | ForEach-Object { @{ Name = $_.BaseName; Path = $_.FullName } })
    }

    It 'matches its schema: app-registrations.json' {
        Test-Json -Path (Join-Path $Root 'app-registrations.json') -SchemaFile (Join-Path $Root 'schemas/app-registrations.schema.json') | Should -BeTrue
    }

    It 'matches its schema and is valid: environment <Name>' -ForEach $Environments {
        Test-Json -Path $Path -SchemaFile (Join-Path $Root 'schemas/environment.schema.json') | Should -BeTrue
        $configuration = Read-AppRegistrationConfiguration -DefinitionPath (Join-Path $Root 'app-registrations.json') -EnvironmentPath $Path
        @(Test-AppRegistrationConfiguration -Configuration $configuration) | Should -BeNullOrEmpty
    }
}

Describe 'Checking a configuration' {
    It 'finds nothing wrong with the test system' {
        Get-Problems | Should -BeNullOrEmpty
    }

    It 'finds a request for a scope or role the own API does not define' {
        $changed = Copy-AsHashtable $script:Definition
        $changed.appRegistrations[1].requiredResourceAccess[1].scopes = @('access_as_admin')
        $changed.appRegistrations[2].requiredResourceAccess[0].roles = @('Orders.Delete')
        $problems = Get-Problems -Definition $changed
        $problems | Should -Contain "Application 'orders-web': requests scope 'access_as_admin' that 'orders-api' does not define."
        $problems | Should -Contain "Application 'orders-worker': requests role 'Orders.Delete' that 'orders-api' does not define."
    }

    It 'finds an application requesting a role that only users can have' {
        $changed = Copy-AsHashtable $script:Definition
        $changed.appRegistrations[2].requiredResourceAccess[0].roles = @('Orders.Admin')
        Get-Problems -Definition $changed | Should -Contain "Application 'orders-worker': requests role 'Orders.Admin' of 'orders-api', which does not allow applications."
    }

    It 'finds a pre-authorized client that does not exist' {
        $changed = Copy-AsHashtable $script:Definition
        $changed.appRegistrations[0].preAuthorizedApplications[0].application = 'orders-mobile'
        Get-Problems -Definition $changed | Should -Contain "Application 'orders-api': pre-authorized application 'orders-mobile' is not an own key, a well-known name or an application ID."
    }

    It 'finds role members for a role no application defines' {
        $environment = New-TestEnvironment
        $environment.roleMembers['Orders.Typo'] = @('orders-readers')
        $environment.roleMembers['orders-mobile/Orders.Read'] = @('orders-readers')
        $problems = Get-Problems -Environment $environment
        $problems | Should -Contain "Environment 'dev': role members 'Orders.Typo' refer to a role no application defines."
        $problems | Should -Contain "Environment 'dev': role members 'orders-mobile/Orders.Read' refer to unknown application 'orders-mobile'."
    }

    It 'finds a redirect URI list the environment does not define' {
        $environment = New-TestEnvironment
        $environment.redirectUris = @{}
        Get-Problems -Environment $environment | Should -Contain "Application 'orders-web': redirect URI list 'orders-web' is not defined in environment 'dev'."
    }

    It 'finds a secret without a name, and duplicate keys and display names' {
        $changed = Copy-AsHashtable $script:Definition
        $changed.appRegistrations[2].credential.Remove('name')
        $changed.appRegistrations += @(Copy-AsHashtable $changed.appRegistrations[0])
        $problems = Get-Problems -Definition $changed
        $problems | Should -Contain "Application 'orders-worker': a secret credential needs a name."
        $problems | Should -Contain "Application 'orders-api': key is used twice."
        $problems | Should -Contain "Application 'orders-api': displayName 'orders-api-dev' is also used by 'orders-api'."
    }

    It 'finds an empty owner list, unless owners are not managed' {
        $environment = New-TestEnvironment
        $environment.owners = @()
        Get-Problems -Environment $environment | Should -Contain "Environment 'dev': owners is empty; set manageOwners to false to leave owners alone."

        $environment.manageOwners = $false
        Get-Problems -Environment $environment | Should -BeNullOrEmpty
    }
}
