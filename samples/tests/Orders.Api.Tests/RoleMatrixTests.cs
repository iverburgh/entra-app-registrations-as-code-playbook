using System.Net;
using Orders.Api.Security;

namespace Orders.Api.Tests;

/// <summary>
/// Who may call what, as a table. Every endpoint is tried with every kind of caller: the callers
/// listed for an endpoint must get through, all others must get 403. A new endpoint or caller
/// added here is automatically tested against everything else.
/// </summary>
public sealed class RoleMatrixTests
{
    private static readonly Dictionary<string, TestToken> Callers = new()
    {
        ["reader"] = TestTokens.User(AppRoles.OrdersRead),
        ["administrator"] = TestTokens.User(AppRoles.OrdersAdmin),
        ["user without a role"] = TestTokens.User(),
        ["reader without the scope"] = TestTokens.User(AppRoles.OrdersRead) with { Scope = "other_scope" },
        ["user with an application role"] = TestTokens.User(AppRoles.OrdersProcess),
        ["processing application"] = TestTokens.Application(AppRoles.OrdersProcess),
        ["application with a user role"] = TestTokens.Application(AppRoles.OrdersRead),
    };

    private static readonly (string Method, string Path, string[] Allowed)[] Endpoints =
    [
        ("GET", "/orders", ["reader", "administrator"]),
        ("GET", "/orders/1/invoice", ["reader", "administrator"]),
        ("POST", "/orders/1/cancel", ["administrator"]),
        ("POST", "/orders/1/process", ["processing application"]),
    ];

    private OrdersApiFactory _factory = null!;

    [OneTimeSetUp]
    public void StartApi() => _factory = new OrdersApiFactory();

    [OneTimeTearDown]
    public void StopApi() => _factory.Dispose();

    private static IEnumerable<TestCaseData> Matrix() =>
        from endpoint in Endpoints
        from caller in Callers.Keys
        let allowed = endpoint.Allowed.Contains(caller)
        select new TestCaseData(endpoint.Method, endpoint.Path, caller, allowed)
            .SetName($"{endpoint.Method} {endpoint.Path} by a {caller} is {(allowed ? "allowed" : "forbidden")}");

    [TestCaseSource(nameof(Matrix))]
    public async Task Access(string method, string path, string caller, bool allowed)
    {
        using var client = _factory.CreateClient(Callers[caller]);
        using var request = new HttpRequestMessage(new HttpMethod(method), path);

        using var response = await client.SendAsync(request);

        if (allowed)
        {
            Assert.That(response.IsSuccessStatusCode, Is.True, $"Expected success, got {(int)response.StatusCode}.");
        }
        else
        {
            Assert.That(response.StatusCode, Is.EqualTo(HttpStatusCode.Forbidden));
        }
    }

    [Test]
    public void Every_caller_in_the_matrix_exists()
    {
        var unknown = Endpoints.SelectMany(endpoint => endpoint.Allowed).Except(Callers.Keys).ToList();

        Assert.That(unknown, Is.Empty, "A typo in an allowed caller would silently turn the test into 'nobody may call this'.");
    }
}
