BeforeAll {
    . "$PSScriptRoot/../lib/AppRegistrations.ps1"
    . "$PSScriptRoot/FakeDirectory.ps1"
    . "$PSScriptRoot/TestSystem.ps1"
    # $PSBoundParameters is empty inside a mock body, so the parameters are passed on by name.
    Mock Invoke-Graph { Invoke-FakeGraph -Method $Method -Uri $Uri -Body $Body -All:$All -AllowNotFound:$AllowNotFound }
    Mock Invoke-AzCli { Invoke-FakeAzCli -Arguments $Arguments -AllowFailure:$AllowFailure }
}

Describe 'A first run on an empty tenant' {
    BeforeAll {
        Initialize-TestTenant
        $script:FirstRun = @(Invoke-AppRegistrationSync -Configuration (Read-TestConfiguration))
        $script:Api = Get-TestApplication 'orders-api-dev'
        $script:Web = Get-TestApplication 'orders-web-dev'
        $script:Worker = Get-TestApplication 'orders-worker-dev'
    }

    It 'creates every application, with a service principal, an identifier URI and v2 tokens' {
        foreach ($application in $Api, $Web, $Worker) {
            $application.identifierUris | Should -Be @("api://$($application.appId)")
            $application.api.requestedAccessTokenVersion | Should -Be 2
            Get-TestServicePrincipal $application.displayName | Should -Not -BeNullOrEmpty
        }
    }

    It 'creates the roles and scopes, enabled' {
        $Api.appRoles.value | Should -Be @('Orders.Read', 'Orders.Admin', 'Orders.Process')
        $Api.appRoles | ForEach-Object { $_.isEnabled | Should -BeTrue }
        $Api.api.oauth2PermissionScopes.value | Should -Be @('access_as_user')
    }

    It 'pre-authorizes the own web client and the Azure CLI by their application IDs' {
        $scopeId = $Api.api.oauth2PermissionScopes[0].id
        $preAuthorized = $Api.api.preAuthorizedApplications
        $preAuthorized.appId | Should -Be @($Web.appId, '04b07795-8ddb-461a-bbee-02f9e1bf7b46')
        $preAuthorized | ForEach-Object { $_.delegatedPermissionIds | Should -Be @($scopeId) }
    }

    It 'requests permissions by ID, resolved from the names in the definition' {
        $graphScope = (Get-FakeServicePrincipal $global:Ids.Graph).oauth2PermissionScopes[0].id
        $Web.requiredResourceAccess | Should -HaveCount 2
        ($Web.requiredResourceAccess | Where-Object resourceAppId -EQ '00000003-0000-0000-c000-000000000000').resourceAccess.id | Should -Be $graphScope
        ($Web.requiredResourceAccess | Where-Object resourceAppId -EQ $Api.appId).resourceAccess[0].type | Should -Be 'Scope'
        ($Worker.requiredResourceAccess | Where-Object resourceAppId -EQ $Api.appId).resourceAccess[0].id | Should -Be ($Api.appRoles | Where-Object value -EQ 'Orders.Process').id
    }

    It 'assigns groups and users; and service principals inside a group directly, as app-only tokens ignore group roles' {
        $readers = Get-TestAssignments 'orders-api-dev' 'Orders.Read'
        $readers | Should -Contain $global:Ids.Readers
        $readers | Should -Contain $global:Ids.Tester
        $readers | Should -Contain $global:Ids.ReaderJob
        $readers | Should -Not -Contain $global:Ids.Reader -Because 'users get the role through the group'
    }

    It 'applies a role member list to every application that defines the role' {
        Get-TestAssignments 'orders-web-dev' 'Orders.Read' | Should -Contain $global:Ids.Readers
    }

    It 'skips service principals in a group for a role that only allows users' {
        Get-TestAssignments 'orders-web-dev' 'Orders.Read' | Should -Not -Contain $global:Ids.ReaderJob
    }

    It 'grants an own application the application permissions it requests on an own API' {
        Get-TestAssignments 'orders-api-dev' 'Orders.Process' | Should -Contain (Get-TestServicePrincipal 'orders-worker-dev').id
        Get-TestAssignments 'orders-api-dev' 'Orders.Process' | Should -Contain $global:Ids.Processor
    }

    It 'does not grant permissions on APIs it does not define: that takes admin consent' {
        @($global:Fake.Assignments | Where-Object resourceId -EQ $global:Ids['Invoices-dev']) | Should -BeNullOrEmpty
    }

    It 'makes the owner group members, nested ones too, and the signed-in identity owners of application and service principal' {
        foreach ($id in $Api.id, (Get-TestServicePrincipal 'orders-api-dev').id) {
            $global:Fake.Owners[$id] | Sort-Object | Should -Be (@($global:Ids.Owner1, $global:Ids.Owner2, $global:Fake.Me) | Sort-Object)
        }
    }

    It 'requires assignment, so only assigned users and applications get tokens' {
        (Get-TestServicePrincipal 'orders-api-dev').appRoleAssignmentRequired | Should -BeTrue
    }

    It 'sets the redirect URIs of the environment' {
        $Web.spa.redirectUris | Should -Be @('http://localhost:5173/', 'https://orders-dev.example.com/')
    }

    It 'creates the certificate in Key Vault with its tags, and adds it without removing other credentials' {
        $global:Fake.Certificates['kv-orders-dev/AppReg-orders-api-dev'].Tags.owner | Should -Be 'orders-team'
        $Api.keyCredentials.displayName | Should -Be 'AppReg-orders-api-dev'
    }

    It 'stores the client secret in Key Vault, and nowhere in the output' {
        $global:Fake.Secrets['kv-orders-dev/AppReg-orders-worker-dev-pipeline'] | Should -Be 'secret-for-orders-worker-dev'
        $Worker.passwordCredentials.displayName | Should -Be 'pipeline'
        ($FirstRun | Out-String) | Should -Not -Match 'secret-for'
    }

    It 'reports every change it made' {
        @($FirstRun | Where-Object Action -EQ 'create application') | Should -HaveCount 3
    }

    It 'changes nothing when run again' {
        $writes = $global:Fake.Writes.Count
        $again = Invoke-AppRegistrationSync -Configuration (Read-TestConfiguration)
        $again | Should -BeNullOrEmpty
        $global:Fake.Writes.Count | Should -Be $writes
    }
}

Describe 'Changes to the definition' {
    BeforeEach {
        Initialize-TestTenant
        $script:Changed = Copy-AsHashtable $script:Definition
        Invoke-AppRegistrationSync -Configuration (Read-TestConfiguration) | Out-Null
    }

    It 'disables a role before changing it, then enables it again' {
        $Changed.appRegistrations[0].appRoles[0].description = 'Read orders and invoices.'
        $result = Invoke-AppRegistrationSync -Configuration (Read-TestConfiguration -Definition $Changed)

        $role = (Get-TestApplication 'orders-api-dev').appRoles | Where-Object value -EQ 'Orders.Read'
        $role.description | Should -Be 'Read orders and invoices.'
        $role.isEnabled | Should -BeTrue
        $result.Action | Should -Contain 'disable role(s) Orders.Read before changing them'
    }

    It 'keeps the ID of a changed role, so assignments survive' {
        $before = ((Get-TestApplication 'orders-api-dev').appRoles | Where-Object value -EQ 'Orders.Read').id
        $Changed.appRegistrations[0].appRoles[0].displayName = 'Reader'
        Invoke-AppRegistrationSync -Configuration (Read-TestConfiguration -Definition $Changed) | Out-Null
        ((Get-TestApplication 'orders-api-dev').appRoles | Where-Object value -EQ 'Orders.Read').id | Should -Be $before
        Get-TestAssignments 'orders-api-dev' 'Orders.Read' | Should -Contain $global:Ids.Readers
    }

    It 'removes a role that is no longer defined' {
        $Changed.appRegistrations[0].appRoles = @($Changed.appRegistrations[0].appRoles | Where-Object { $_.value -ne 'Orders.Admin' })
        Invoke-AppRegistrationSync -Configuration (Read-TestConfiguration -Definition $Changed) | Out-Null
        (Get-TestApplication 'orders-api-dev').appRoles.value | Should -Not -Contain 'Orders.Admin'
    }

    It 'removes a scope that is still pre-authorized' {
        $Changed.appRegistrations[0].scopes += @{ value = 'legacy'; adminConsentDisplayName = 'Legacy' }
        $Changed.appRegistrations[0].preAuthorizedApplications[1].scopes = @('access_as_user', 'legacy')
        Invoke-AppRegistrationSync -Configuration (Read-TestConfiguration -Definition $Changed) | Out-Null

        $Changed.appRegistrations[0].scopes = @($Changed.appRegistrations[0].scopes | Where-Object { $_.value -ne 'legacy' })
        $Changed.appRegistrations[0].preAuthorizedApplications[1].scopes = @('access_as_user')
        Invoke-AppRegistrationSync -Configuration (Read-TestConfiguration -Definition $Changed) | Out-Null

        (Get-TestApplication 'orders-api-dev').api.oauth2PermissionScopes.value | Should -Be @('access_as_user')
    }

    It 'leaves alone what a definition does not mention' {
        $application = Get-TestApplication 'orders-web-dev'
        $application.api.oauth2PermissionScopes = @([pscustomobject]@{ id = (New-Guid).Guid; value = 'made-in-portal'; isEnabled = $true })
        Invoke-AppRegistrationSync -Configuration (Read-TestConfiguration) | Should -BeNullOrEmpty
    }

    It 'updates redirect URIs and keeps the other web settings' {
        $Changed.appRegistrations[1].redirectUris = @{ web = 'orders-web' }
        $application = Get-TestApplication 'orders-web-dev'
        $application.web.implicitGrantSettings.enableIdTokenIssuance = $true
        Invoke-AppRegistrationSync -Configuration (Read-TestConfiguration -Definition $Changed) | Out-Null
        $application = Get-TestApplication 'orders-web-dev'
        $application.web.redirectUris | Should -Be @('http://localhost:5173/', 'https://orders-dev.example.com/')
        $application.web.implicitGrantSettings.enableIdTokenIssuance | Should -BeTrue
    }

    It 'updates certificate tags and keeps tags added elsewhere' {
        $global:Fake.Certificates['kv-orders-dev/AppReg-orders-api-dev'].Tags.costCenter = '42'
        $Changed.appRegistrations[0].credential.tags = @{ owner = 'platform-team' }
        Invoke-AppRegistrationSync -Configuration (Read-TestConfiguration -Definition $Changed) | Out-Null
        $tags = $global:Fake.Certificates['kv-orders-dev/AppReg-orders-api-dev'].Tags
        $tags.owner | Should -Be 'platform-team'
        $tags.costCenter | Should -Be '42'
    }
}

Describe 'Drift in the tenant' {
    BeforeEach {
        Initialize-TestTenant
        Invoke-AppRegistrationSync -Configuration (Read-TestConfiguration) | Out-Null
        $script:Sp = Get-FakeServicePrincipal (Get-TestServicePrincipal 'orders-api-dev').id
        $script:AdminRole = ($Sp.appRoles | Where-Object value -EQ 'Orders.Admin').id
    }

    It 'removes a role assignment made by hand' {
        Invoke-FakeGraph -Method POST -Uri "/servicePrincipals/$($Sp.id)/appRoleAssignedTo" -Body @{ principalId = $global:Ids.Reader; resourceId = $Sp.id; appRoleId = $AdminRole } | Out-Null
        $result = Invoke-AppRegistrationSync -Configuration (Read-TestConfiguration)
        Get-TestAssignments 'orders-api-dev' 'Orders.Admin' | Should -Not -Contain $global:Ids.Reader
        $result.Action | Should -Contain "remove role 'Orders.Admin' from Reader"
    }

    It 'restores an assignment removed by hand' {
        $assignment = $global:Fake.Assignments | Where-Object { $_.principalId -eq $global:Ids.Readers -and $_.resourceId -eq $Sp.id } | Select-Object -First 1
        [void]$global:Fake.Assignments.Remove($assignment)
        Invoke-AppRegistrationSync -Configuration (Read-TestConfiguration) | Out-Null
        Get-TestAssignments 'orders-api-dev' 'Orders.Read' | Should -Contain $global:Ids.Readers
    }

    It 'leaves role assignments alone when the environment does not manage them' {
        Invoke-FakeGraph -Method POST -Uri "/servicePrincipals/$($Sp.id)/appRoleAssignedTo" -Body @{ principalId = $global:Ids.Reader; resourceId = $Sp.id; appRoleId = $AdminRole } | Out-Null
        $environment = New-TestEnvironment
        $environment.manageRoleAssignments = $false
        Invoke-AppRegistrationSync -Configuration (Read-TestConfiguration -Environment $environment) | Should -BeNullOrEmpty
    }

    It 'removes an owner added by hand, and leaves owners alone when the environment does not manage them' {
        $global:Fake.Owners[(Get-TestApplication 'orders-api-dev').id].Add($global:Ids.Reader)
        $environment = New-TestEnvironment
        $environment.manageOwners = $false
        Invoke-AppRegistrationSync -Configuration (Read-TestConfiguration -Environment $environment) | Should -BeNullOrEmpty

        Invoke-AppRegistrationSync -Configuration (Read-TestConfiguration) | Out-Null
        $global:Fake.Owners[(Get-TestApplication 'orders-api-dev').id] | Should -Not -Contain $global:Ids.Reader
    }

    It 'warns when a client secret exists but its Key Vault copy is gone' {
        $global:Fake.Secrets.Clear()
        Invoke-AppRegistrationSync -Configuration (Read-TestConfiguration) -WarningVariable warnings -WarningAction SilentlyContinue | Out-Null
        $warnings | Should -Match 'cannot be read back'
    }
}

Describe 'A dry run' {
    It 'plans everything on an empty tenant and writes nothing' {
        Initialize-TestTenant
        $plan = Invoke-AppRegistrationSync -Configuration (Read-TestConfiguration) -DryRun
        $global:Fake.Writes | Should -BeNullOrEmpty
        @($plan | Where-Object Action -EQ 'create application') | Should -HaveCount 3
        $plan.Action | Should -Contain "assign role 'Orders.Process' to orders-worker-dev"
        $plan.Action | Should -Contain "add client secret 'pipeline' and store it in Key Vault 'kv-orders-dev' as 'AppReg-orders-worker-dev-pipeline'"
    }

    It 'plans nothing on an up-to-date tenant' {
        Initialize-TestTenant
        Invoke-AppRegistrationSync -Configuration (Read-TestConfiguration) | Out-Null
        Invoke-AppRegistrationSync -Configuration (Read-TestConfiguration) -DryRun | Should -BeNullOrEmpty
    }

    It 'plans exactly the changes a real run then makes' {
        Initialize-TestTenant
        Invoke-AppRegistrationSync -Configuration (Read-TestConfiguration) | Out-Null
        $changed = Copy-AsHashtable $script:Definition
        $changed.appRegistrations[0].appRoles += @{ value = 'Orders.Export'; displayName = 'Exporter'; allowedMemberTypes = @('User') }
        $plan = Invoke-AppRegistrationSync -Configuration (Read-TestConfiguration -Definition $changed) -DryRun
        $made = Invoke-AppRegistrationSync -Configuration (Read-TestConfiguration -Definition $changed)
        $made.Action | Should -Be $plan.Action
    }
}

Describe 'Resolving people, groups and services' {
    BeforeEach { Initialize-TestTenant }

    It 'stops on a name that does not exist, instead of removing access' {
        $environment = New-TestEnvironment
        $environment.roleMembers['Orders.Admin'] = @('orders-admins-typo')
        { Invoke-AppRegistrationSync -Configuration (Read-TestConfiguration -Environment $environment) } | Should -Throw '*orders-admins-typo*not found*'
    }

    It 'skips such a name when asked to' {
        $environment = New-TestEnvironment
        $environment.roleMembers['Orders.Admin'] = @('orders-admins-typo')
        { Invoke-AppRegistrationSync -Configuration (Read-TestConfiguration -Environment $environment) -AllowUnresolvedPrincipals -WarningAction SilentlyContinue } | Should -Not -Throw
    }

    It 'stops on a name that matches two groups' {
        Add-FakeGroup 'orders-readers' | Out-Null
        { Invoke-AppRegistrationSync -Configuration (Read-TestConfiguration) } | Should -Throw '*matches 2 objects*'
    }

    It 'refuses a user in a role that only allows applications' {
        $environment = New-TestEnvironment
        $environment.roleMembers['Orders.Process'] = @('user:tester@example.com')
        { Invoke-AppRegistrationSync -Configuration (Read-TestConfiguration -Environment $environment) } | Should -Throw "*role 'Orders.Process' does not allow users*"
    }

    It 'uses the prefix to tell a group and a service principal with the same name apart' {
        $spId = Add-FakeServicePrincipal -DisplayName 'orders-readers'
        $environment = New-TestEnvironment
        $environment.roleMembers['Orders.Process'] = @('sp:orders-readers')
        Invoke-AppRegistrationSync -Configuration (Read-TestConfiguration -Environment $environment) | Out-Null
        Get-TestAssignments 'orders-api-dev' 'Orders.Process' | Should -Contain $spId
    }

    It 'stops when two applications have the same display name' {
        Invoke-FakeGraph -Method POST -Uri '/applications' -Body @{ displayName = 'orders-api-dev'; api = @{ requestedAccessTokenVersion = 2 } } | Out-Null
        Invoke-FakeGraph -Method POST -Uri '/applications' -Body @{ displayName = 'orders-api-dev'; api = @{ requestedAccessTokenVersion = 2 } } | Out-Null
        { Invoke-AppRegistrationSync -Configuration (Read-TestConfiguration) } | Should -Throw "*2 applications named 'orders-api-dev'*"
    }

    It 'keeps a signed-in service principal as owner, so a pipeline does not lock itself out' {
        $pipeline = Add-FakeServicePrincipal -DisplayName 'pipeline-identity' -AppId 'pipeline-app-id'
        $global:Fake.Account = @{ tenantId = 'contoso-tenant'; user = @{ name = 'pipeline-app-id'; type = 'servicePrincipal' } }
        Invoke-AppRegistrationSync -Configuration (Read-TestConfiguration) | Out-Null
        $global:Fake.Owners[(Get-TestApplication 'orders-api-dev').id] | Should -Contain $pipeline
    }
}

Describe 'A credential stored in Key Vault' {
    It 'takes a new client secret off the application again when Key Vault refuses it' {
        Initialize-TestTenant
        Mock Invoke-AzCli { if ((@($Arguments | Select-Object -First 3) -join ' ') -eq 'keyvault secret set') { throw 'Forbidden' } Invoke-FakeAzCli -Arguments $Arguments -AllowFailure:$AllowFailure }
        { Invoke-AppRegistrationSync -Configuration (Read-TestConfiguration) } | Should -Throw '*Forbidden*'
        (Get-TestApplication 'orders-worker-dev').passwordCredentials | Should -BeNullOrEmpty
    }
}
