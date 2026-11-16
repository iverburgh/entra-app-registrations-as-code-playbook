using System.Reflection;
using System.Text.Json;
using Orders.Gateway.Security;

namespace Orders.Gateway.Tests;

/// <summary>
/// The gateway's code and configuration agree with its app registration. A scope the gateway asks
/// for that its registration does not request is a consent nobody was ever asked for: the exchange
/// fails with AADSTS65001 for every user.
/// </summary>
public sealed class DefinitionContractTests
{
    private static readonly JsonElement Gateway = Registration("orders-gateway");

    [Test]
    public void The_scope_constants_are_the_scopes_of_the_definition() =>
        Assert.That(
            typeof(GatewayScopes).GetFields(BindingFlags.Public | BindingFlags.Static).Select(field => (string)field.GetRawConstantValue()!),
            Is.EquivalentTo(Gateway.GetProperty("scopes").EnumerateArray().Select(scope => scope.GetProperty("value").GetString())));

    [Test]
    public void Every_downstream_scope_in_the_routes_is_requested_by_the_app_registration()
    {
        using var settings = JsonDocument.Parse(File.ReadAllText(FindAbove("samples/src/Orders.Gateway/appsettings.json")));
        var requested = Gateway.GetProperty("requiredResourceAccess").EnumerateArray()
            .SelectMany(access => access.GetProperty("scopes").EnumerateArray()
                .Select(scope => (Resource: access.GetProperty("resource").GetString()!, Scope: scope.GetString()!)))
            .ToList();

        foreach (var cluster in settings.RootElement.GetProperty("ReverseProxy").GetProperty("Clusters").EnumerateObject())
        {
            var scope = cluster.Value.GetProperty("Metadata").GetProperty("Scope").GetString()!;
            var name = scope[(scope.LastIndexOf('/') + 1)..];
            Assert.That(
                requested.Any(r => r.Resource.StartsWith(cluster.Name, StringComparison.Ordinal) && r.Scope == name),
                $"Cluster '{cluster.Name}' asks for '{name}', which orders-gateway does not request.");
        }
    }

    [Test]
    public void The_spa_that_calls_the_gateway_is_a_known_client_and_pre_authorized()
    {
        var spa = Registration("orders-web");
        Assert.That(
            spa.GetProperty("requiredResourceAccess").EnumerateArray().Select(access => access.GetProperty("resource").GetString()),
            Does.Contain("orders-gateway"));
        Assert.That(Gateway.GetProperty("knownClientApplications").EnumerateArray().Select(client => client.GetString()), Does.Contain("orders-web"));
        Assert.That(
            Gateway.GetProperty("preAuthorizedApplications").EnumerateArray().Select(client => client.GetProperty("application").GetString()),
            Does.Contain("orders-web"));
    }

    [Test]
    public void The_gateway_has_no_roles_so_it_does_not_require_assignment()
    {
        Assert.That(Gateway.GetProperty("appRoles").GetArrayLength(), Is.Zero);
        Assert.That(
            Gateway.TryGetProperty("assignmentRequired", out var required) && required.ValueKind == JsonValueKind.False,
            "With assignment required and no roles to assign, nobody gets a token for the gateway.");
    }

    private static JsonElement Registration(string key)
    {
        using var document = JsonDocument.Parse(File.ReadAllText(FindAbove("app-registrations/app-registrations.json")));
        return document.RootElement.GetProperty("appRegistrations").EnumerateArray()
            .Single(app => app.GetProperty("key").GetString() == key)
            .Clone();
    }

    private static string FindAbove(string relativePath)
    {
        for (var directory = new DirectoryInfo(AppContext.BaseDirectory); directory is not null; directory = directory.Parent)
        {
            var candidate = Path.Combine(directory.FullName, relativePath);
            if (File.Exists(candidate))
            {
                return candidate;
            }
        }

        throw new FileNotFoundException($"{relativePath} not found above {AppContext.BaseDirectory}.");
    }
}
