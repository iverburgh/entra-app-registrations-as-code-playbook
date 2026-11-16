using System.Security.Claims;
using Microsoft.AspNetCore.Http;
using Microsoft.Extensions.Options;
using Orders.Gateway.Proxy;
using Orders.Gateway.Security;
using Yarp.ReverseProxy.Configuration;

namespace Orders.Gateway.Tests;

public sealed class PathBasedTokenValidatorTests
{
    private const string Gateway = "gateway-client-id";

    private static readonly PathBasedTokenValidator Validator = new(
        new InMemoryConfigProvider(
            [
                new RouteConfig { RouteId = "orders", ClusterId = "orders-api", Match = new RouteMatch { Path = "/api/orders/{**rest}" } },
                new RouteConfig { RouteId = "invoices", ClusterId = "invoices-api", Match = new RouteMatch { Path = "/api/invoices/{**rest}" } },
            ],
            []),
        Options.Create(new EntraIdOptions { TenantId = "tenant", ClientId = Gateway }));

    [TestCase("/api/orders")]
    [TestCase("/api/orders/")]
    [TestCase("/api/orders/42/invoice")]
    [TestCase("/API/Invoices/7")]
    public void Accepts_a_gateway_token_on_a_path_a_route_covers(string path) =>
        Assert.That(Validator.Validate(new PathString(path), Principal(Gateway)), Is.Null);

    [TestCase("/api/orders-admin/1")]
    [TestCase("/api")]
    [TestCase("/")]
    [TestCase("/health")]
    public void Rejects_a_path_no_route_covers(string path) =>
        Assert.That(Validator.Validate(new PathString(path), Principal(Gateway)), Does.Contain("No route"));

    [Test]
    public void Rejects_a_token_for_another_api() =>
        Assert.That(Validator.Validate(new PathString("/api/orders/"), Principal("orders-api-client-id")), Does.Contain("audience"));

    [Test]
    public void Rejects_a_token_with_more_than_one_audience() =>
        Assert.That(Validator.Validate(new PathString("/api/orders/"), Principal(Gateway, "orders-api-client-id")), Does.Contain("audience"));

    [Test]
    public void Rejects_a_missing_principal() =>
        Assert.That(Validator.Validate(new PathString("/api/orders/"), principal: null), Is.Not.Null);

    [TestCase("/api/orders/{**rest}", "/api/orders")]
    [TestCase("/api/orders/{id}/invoice", "/api/orders")]
    [TestCase("/api/orders", "/api/orders")]
    [TestCase("/{**catch-all}", "")]
    [TestCase(null, "")]
    public void The_literal_prefix_is_the_path_before_the_first_parameter(string? pattern, string prefix) =>
        Assert.That(RoutePaths.LiteralPrefix(pattern), Is.EqualTo(prefix));

    private static ClaimsPrincipal Principal(params string[] audiences) =>
        new(new ClaimsIdentity(audiences.Select(audience => new Claim("aud", audience)), "Bearer"));
}
