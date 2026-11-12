using System.Reflection;
using System.Text.Json;
using Orders.Api.Security;

namespace Orders.Api.Tests;

/// <summary>
/// The role and scope values in the code are the ones the app registration defines. A value that
/// differs is a role nobody can have: the endpoint behind it would be closed to everyone.
/// </summary>
public sealed class DefinitionContractTests
{
    private const string Definitions = "app-registrations/app-registrations.json";

    [Test]
    public void The_role_constants_are_the_app_roles_of_the_definition() =>
        Assert.That(Constants(typeof(AppRoles)), Is.EquivalentTo(Values("appRoles")));

    [Test]
    public void The_scope_constants_are_the_scopes_of_the_definition() =>
        Assert.That(Constants(typeof(AppScopes)), Is.EquivalentTo(Values("scopes")));

    private static IEnumerable<string> Constants(Type type) =>
        type.GetFields(BindingFlags.Public | BindingFlags.Static)
            .Where(field => field.IsLiteral)
            .Select(field => (string)field.GetRawConstantValue()!);

    private static IEnumerable<string> Values(string property)
    {
        using var document = JsonDocument.Parse(File.ReadAllText(FindDefinitions()));
        var api = document.RootElement.GetProperty("appRegistrations").EnumerateArray()
            .Single(app => app.GetProperty("key").GetString() == "orders-api");
        return api.GetProperty(property).EnumerateArray().Select(item => item.GetProperty("value").GetString()!).ToList();
    }

    private static string FindDefinitions()
    {
        for (var directory = new DirectoryInfo(TestContext.CurrentContext.TestDirectory); directory is not null; directory = directory.Parent)
        {
            var candidate = Path.Combine(directory.FullName, Definitions);
            if (File.Exists(candidate))
            {
                return candidate;
            }
        }

        throw new FileNotFoundException($"{Definitions} not found above {TestContext.CurrentContext.TestDirectory}.");
    }
}
