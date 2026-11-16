using System.Net;
using System.Net.Http.Headers;
using Microsoft.Identity.Client;

namespace Orders.Gateway.Tests;

/// <summary>What leaves the gateway, and what the SPA gets back, for each kind of request.</summary>
public sealed class ProxyTests
{
    private GatewayFactory _gateway = null!;

    [SetUp]
    public void StartGateway() => _gateway = new GatewayFactory();

    [TearDown]
    public void StopGateway() => _gateway.Dispose();

    [TestCase("/api/orders/", GatewayFactory.OrdersScope, "https://orders.test/orders/")]
    [TestCase("/api/orders/42/invoice", GatewayFactory.OrdersScope, "https://orders.test/orders/42/invoice")]
    [TestCase("/api/invoices/7", GatewayFactory.InvoicesScope, "https://invoices.test/invoices/7")]
    public async Task Each_route_gets_a_token_for_the_scope_of_its_api(string path, string scope, string forwardedTo)
    {
        var token = TestTokens.User().Serialize();
        using var client = _gateway.CreateClient();
        client.DefaultRequestHeaders.Authorization = new AuthenticationHeaderValue("Bearer", token);

        using var response = await client.GetAsync(path);

        Assert.That(response.StatusCode, Is.EqualTo(HttpStatusCode.OK));
        Assert.That(_gateway.TokenSource.Exchanges.Single(), Is.EqualTo(new Exchange(token, scope)));
        var forwarded = _gateway.Apis.Requests.Single();
        Assert.That(forwarded.Uri, Is.EqualTo(new Uri(forwardedTo)));
        Assert.That(forwarded.Authorization, Is.EqualTo($"Bearer obo-token-for {scope}"));
    }

    [Test]
    public async Task The_users_own_token_and_cookies_never_reach_the_api()
    {
        var token = TestTokens.User().Serialize();
        using var client = _gateway.CreateClient();
        using var request = new HttpRequestMessage(HttpMethod.Get, "/api/orders/");
        request.Headers.Authorization = new AuthenticationHeaderValue("Bearer", token);
        request.Headers.Add("Cookie", "session=secret");

        using var response = await client.SendAsync(request);

        var forwarded = _gateway.Apis.Requests.Single();
        Assert.That(forwarded.Authorization, Does.Not.Contain(token));
        Assert.That(forwarded.HasCookie, Is.False);
    }

    [Test]
    public async Task A_request_without_a_token_is_challenged_and_not_forwarded()
    {
        using var client = _gateway.CreateClient(token: null);

        using var response = await client.GetAsync("/api/orders/");

        Assert.That(response.StatusCode, Is.EqualTo(HttpStatusCode.Unauthorized));
        Assert.That(_gateway.Apis.Requests, Is.Empty);
    }

    [Test]
    public async Task A_token_for_another_audience_is_rejected_not_passed_on()
    {
        using var client = _gateway.CreateClient(TestTokens.User() with { Audience = Guid.NewGuid().ToString() });

        using var response = await client.GetAsync("/api/orders/");

        Assert.That(response.StatusCode, Is.EqualTo(HttpStatusCode.Unauthorized));
        Assert.That(_gateway.TokenSource.Exchanges, Is.Empty);
        Assert.That(_gateway.Apis.Requests, Is.Empty);
    }

    [Test]
    public async Task A_token_without_the_gateway_scope_is_forbidden()
    {
        using var client = _gateway.CreateClient(TestTokens.User() with { Scope = null });

        using var response = await client.GetAsync("/api/orders/");

        Assert.That(response.StatusCode, Is.EqualTo(HttpStatusCode.Forbidden));
        Assert.That(_gateway.Apis.Requests, Is.Empty);
    }

    [TestCase("/api/orders-admin/1")]
    [TestCase("/api/unknown")]
    [TestCase("/orders/")]
    public async Task A_path_no_route_covers_fails_closed(string path)
    {
        using var client = _gateway.CreateClient(TestTokens.User());

        using var response = await client.GetAsync(path);

        Assert.That(response.StatusCode, Is.EqualTo(HttpStatusCode.Unauthorized));
        Assert.That(_gateway.TokenSource.Exchanges, Is.Empty);
        Assert.That(_gateway.Apis.Requests, Is.Empty);
    }

    [Test]
    public async Task Consent_or_sign_in_needed_becomes_a_challenge_the_spa_can_act_on()
    {
        _gateway.TokenSource.Exchange = _ => throw new MsalUiRequiredException("invalid_grant", "AADSTS65001: consent required.");
        using var client = _gateway.CreateClient(TestTokens.User());

        using var response = await client.GetAsync("/api/orders/");

        Assert.That(response.StatusCode, Is.EqualTo(HttpStatusCode.Unauthorized));
        var challenge = response.Headers.WwwAuthenticate.Single();
        Assert.That(challenge.Scheme, Is.EqualTo("Bearer"));
        Assert.That(challenge.Parameter, Does.Contain("error=\"interaction_required\""));
        Assert.That(challenge.Parameter, Does.Contain($"scope=\"api://{TestTokens.GatewayClientId}/.default\""));
        Assert.That(_gateway.Apis.Requests, Is.Empty);
    }

    [Test]
    public async Task Any_other_failed_exchange_is_a_bad_gateway_not_a_reason_to_sign_in_again()
    {
        _gateway.TokenSource.Exchange = _ => throw new MsalServiceException("invalid_client", "AADSTS700027: certificate not valid.");
        using var client = _gateway.CreateClient(TestTokens.User());

        using var response = await client.GetAsync("/api/orders/");

        Assert.That(response.StatusCode, Is.EqualTo(HttpStatusCode.BadGateway));
        Assert.That(response.Headers.WwwAuthenticate, Is.Empty);
        Assert.That(_gateway.Apis.Requests, Is.Empty);
    }

    [Test]
    public async Task A_403_from_the_api_reaches_the_spa_unchanged()
    {
        _gateway.Apis.Respond = () => new HttpResponseMessage(HttpStatusCode.Forbidden) { Content = new StringContent("missing role") };
        using var client = _gateway.CreateClient(TestTokens.User());

        using var response = await client.GetAsync("/api/orders/");

        Assert.That(response.StatusCode, Is.EqualTo(HttpStatusCode.Forbidden));
        Assert.That(await response.Content.ReadAsStringAsync(), Is.EqualTo("missing role"));
    }

    [Test]
    public async Task A_401_from_the_api_becomes_a_bad_gateway_so_the_spa_does_not_loop()
    {
        _gateway.Apis.Respond = () =>
        {
            var unauthorized = new HttpResponseMessage(HttpStatusCode.Unauthorized) { Content = new StringContent("bad token") };
            unauthorized.Headers.WwwAuthenticate.Add(new AuthenticationHeaderValue("Bearer", "error=\"invalid_token\""));
            return unauthorized;
        };
        using var client = _gateway.CreateClient(TestTokens.User());

        using var response = await client.GetAsync("/api/orders/");

        Assert.That(response.StatusCode, Is.EqualTo(HttpStatusCode.BadGateway));
        Assert.That(response.Headers.WwwAuthenticate, Is.Empty);
        Assert.That(await response.Content.ReadAsStringAsync(), Is.Empty);
    }

    [Test]
    public async Task The_health_endpoint_answers_without_a_token()
    {
        using var client = _gateway.CreateClient(token: null);

        using var response = await client.GetAsync("/health");

        Assert.That(response.StatusCode, Is.EqualTo(HttpStatusCode.OK));
        Assert.That(_gateway.Apis.Requests, Is.Empty);
    }

    [Test]
    public async Task A_cors_preflight_from_the_spa_needs_no_token()
    {
        using var client = _gateway.CreateClient(token: null);
        using var request = new HttpRequestMessage(HttpMethod.Options, "/api/orders/");
        request.Headers.Add("Origin", GatewayFactory.SpaOrigin);
        request.Headers.Add("Access-Control-Request-Method", "GET");
        request.Headers.Add("Access-Control-Request-Headers", "authorization");

        using var response = await client.SendAsync(request);

        Assert.That(response.StatusCode, Is.EqualTo(HttpStatusCode.NoContent));
        Assert.That(response.Headers.GetValues("Access-Control-Allow-Origin"), Is.EqualTo(new[] { GatewayFactory.SpaOrigin }));
        Assert.That(_gateway.Apis.Requests, Is.Empty);
    }

    [Test]
    public async Task A_cors_preflight_from_another_origin_is_not_allowed()
    {
        using var client = _gateway.CreateClient(token: null);
        using var request = new HttpRequestMessage(HttpMethod.Options, "/api/orders/");
        request.Headers.Add("Origin", "https://evil.example.com");
        request.Headers.Add("Access-Control-Request-Method", "GET");

        using var response = await client.SendAsync(request);

        Assert.That(response.Headers.Contains("Access-Control-Allow-Origin"), Is.False);
        Assert.That(_gateway.Apis.Requests, Is.Empty);
    }
}
