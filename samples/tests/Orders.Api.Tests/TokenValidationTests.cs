using System.Net;
using System.Net.Http.Headers;
using Orders.Api.Security;

namespace Orders.Api.Tests;

/// <summary>
/// Every way a token can be wrong, each rejected with 401 before authorization is even considered.
/// Each case starts from a token that is accepted, and changes one thing.
/// </summary>
public sealed class TokenValidationTests
{
    private OrdersApiFactory _factory = null!;

    [OneTimeSetUp]
    public void StartApi() => _factory = new OrdersApiFactory();

    [OneTimeTearDown]
    public void StopApi() => _factory.Dispose();

    private static TestToken Valid => TestTokens.User(AppRoles.OrdersRead);

    [Test]
    public async Task A_valid_token_is_accepted()
    {
        using var response = await _factory.CreateClient(Valid).GetAsync("/orders");

        Assert.That(response.StatusCode, Is.EqualTo(HttpStatusCode.OK));
    }

    private static IEnumerable<TestCaseData> InvalidTokens()
    {
        yield return new TestCaseData(Valid with { Expires = DateTime.UtcNow.AddHours(-1) })
            .SetName("An expired token is rejected (beyond the clock skew)");
        yield return new TestCaseData(Valid with { Issuer = $"{TestTokens.Instance}{Guid.NewGuid()}/v2.0" })
            .SetName("A token from another tenant is rejected");
        yield return new TestCaseData(Valid with { Issuer = $"https://sts.windows.net/{TestTokens.TenantId}/" })
            .SetName("A v1 token is rejected (other issuer format)");
        yield return new TestCaseData(Valid with { Audience = Guid.NewGuid().ToString() })
            .SetName("A token for another API is rejected");
        yield return new TestCaseData(Valid with { Audience = $"api://{TestTokens.ApiClientId}" })
            .SetName("A token with the application ID URI as audience is rejected (v1 format)");
        yield return new TestCaseData(Valid with { Key = TestTokens.UntrustedKey })
            .SetName("A token signed with an untrusted key is rejected");
    }

    [TestCaseSource(nameof(InvalidTokens))]
    public async Task Invalid_token(TestToken token)
    {
        using var response = await _factory.CreateClient(token).GetAsync("/orders");

        Assert.That(response.StatusCode, Is.EqualTo(HttpStatusCode.Unauthorized));
    }

    [Test]
    public async Task A_request_without_a_token_is_rejected()
    {
        using var response = await _factory.CreateClient(token: null).GetAsync("/orders");

        Assert.That(response.StatusCode, Is.EqualTo(HttpStatusCode.Unauthorized));
    }

    [Test]
    public async Task A_malformed_token_is_rejected()
    {
        using var client = _factory.CreateClient();
        client.DefaultRequestHeaders.Authorization = new AuthenticationHeaderValue("Bearer", "not-a-token");

        using var response = await client.GetAsync("/orders");

        Assert.That(response.StatusCode, Is.EqualTo(HttpStatusCode.Unauthorized));
    }

    [Test]
    public async Task The_health_endpoint_needs_no_token()
    {
        using var response = await _factory.CreateClient(token: null).GetAsync("/health");

        Assert.That(response.StatusCode, Is.EqualTo(HttpStatusCode.OK));
    }
}
