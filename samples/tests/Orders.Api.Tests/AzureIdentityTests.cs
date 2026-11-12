using Microsoft.Extensions.Configuration;
using Orders.Api.Identity;

namespace Orders.Api.Tests;

public sealed class AzureIdentityTests
{
    private static readonly string ClientId = Guid.NewGuid().ToString();

    private static IConfiguration Configuration(string? type, string? clientId) =>
        new ConfigurationBuilder()
            .AddInMemoryCollection(new Dictionary<string, string?>
            {
                ["ManagedIdentity:Type"] = type,
                ["ManagedIdentity:ClientId"] = clientId,
            })
            .Build();

    [Test]
    public void Without_configuration_the_developer_credential_is_used() =>
        Assert.That(AzureIdentity.FromConfiguration(Configuration(null, null)), Is.EqualTo(AzureIdentity.Developer));

    [Test]
    public void A_system_assigned_identity_is_used_when_configured() =>
        Assert.That(AzureIdentity.FromConfiguration(Configuration("SystemAssigned", null)).Kind, Is.EqualTo(AzureIdentityKind.SystemAssigned));

    [Test]
    public void A_user_assigned_identity_is_used_with_its_client_id() =>
        Assert.That(AzureIdentity.FromConfiguration(Configuration("UserAssigned", ClientId)),
            Is.EqualTo(new AzureIdentity(AzureIdentityKind.UserAssigned, ClientId)));

    [TestCase(null, "a1b2", TestName = "A client ID without a type is ambiguous")]
    [TestCase("SystemAssigned", "a1b2", TestName = "A system-assigned identity with a client ID is contradictory")]
    [TestCase("UserAssigned", null, TestName = "A user-assigned identity needs a client ID")]
    [TestCase("UserAssigned", "not-a-guid", TestName = "A user-assigned identity needs a GUID as client ID")]
    [TestCase("Automatic", null, TestName = "An unknown identity type is rejected")]
    public void Unclear_configuration_fails_at_startup(string? type, string? clientId) =>
        Assert.Throws<InvalidOperationException>(() => AzureIdentity.FromConfiguration(Configuration(type, clientId)));

    [TestCase(null)]
    [TestCase("")]
    public void Without_an_authentication_string_telemetry_uses_the_instrumentation_key(string? value) =>
        Assert.That(AzureIdentity.FromApplicationInsightsAuthenticationString(value), Is.Null);

    [Test]
    public void Authorization_AAD_means_the_system_assigned_identity() =>
        Assert.That(AzureIdentity.FromApplicationInsightsAuthenticationString("Authorization=AAD")!.Kind,
            Is.EqualTo(AzureIdentityKind.SystemAssigned));

    [Test]
    public void A_client_id_means_that_user_assigned_identity() =>
        Assert.That(AzureIdentity.FromApplicationInsightsAuthenticationString($"Authorization=AAD;ClientId={ClientId}"),
            Is.EqualTo(new AzureIdentity(AzureIdentityKind.UserAssigned, ClientId)));

    [TestCase("ClientId=abc", TestName = "Authorization=AAD is required")]
    [TestCase("Authorization=Key", TestName = "Only AAD is supported")]
    [TestCase("Authorization=AAD;Authorization=AAD", TestName = "Duplicate keys are rejected")]
    [TestCase("Authorization=AAD;Tenant=x", TestName = "Unknown keys are rejected")]
    [TestCase("Authorization", TestName = "A key without a value is rejected")]
    public void An_invalid_authentication_string_fails(string value) =>
        Assert.Throws<InvalidOperationException>(() => AzureIdentity.FromApplicationInsightsAuthenticationString(value));
}
