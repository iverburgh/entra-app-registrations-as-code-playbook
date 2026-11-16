using Microsoft.Extensions.Configuration;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.Extensions.Logging.Abstractions;
using Microsoft.Extensions.Options;
using Orders.Gateway.Downstream;
using Orders.Gateway.Proxy;
using Orders.Gateway.Security;
using Yarp.ReverseProxy.Configuration;
using Yarp.ReverseProxy.Transforms.Builder;

namespace Orders.Gateway.Tests;

/// <summary>A gateway configuration that would forward too much, or the wrong token, does not start.</summary>
public sealed class ConfigurationTests
{
    private static readonly OnBehalfOfTransformProvider Provider = new(
        Options.Create(new EntraIdOptions { TenantId = "tenant", ClientId = "gateway" }),
        NullLogger<OnBehalfOfTransformProvider>.Instance);

    [TestCase("api://orders/access_as_user")]
    [TestCase("api://orders/.default")]
    [TestCase("https://orders.example.com/access_as_user")]
    public void A_cluster_with_the_scope_of_its_api_is_valid(string scope) =>
        Assert.That(ClusterErrors(new Dictionary<string, string> { ["Scope"] = scope }), Is.Empty);

    [TestCase(null)]
    [TestCase("")]
    [TestCase("access_as_user")]
    [TestCase("api://orders")]
    [TestCase("api://<application-id-of-orders-api>/access_as_user")]
    [TestCase("http://orders.example.com/access_as_user")]
    public void A_cluster_without_a_usable_scope_is_rejected(string? scope) =>
        Assert.That(
            ClusterErrors(scope is null ? null : new Dictionary<string, string> { ["Scope"] = scope }),
            Has.One.Message.Contains("needs metadata 'Scope'"));

    [Test]
    public void A_route_below_a_literal_path_is_valid() =>
        Assert.That(RouteErrors(new RouteConfig { RouteId = "orders", Match = new RouteMatch { Path = "/api/orders/{**rest}" } }), Is.Empty);

    [TestCase("/{**catch-all}")]
    [TestCase("/")]
    [TestCase("{**rest}")]
    [TestCase(null)]
    public void A_catch_all_route_is_rejected(string? path) =>
        Assert.That(
            RouteErrors(new RouteConfig { RouteId = "everything", Match = new RouteMatch { Path = path } }),
            Has.One.Message.Contains("catch-all"));

    [Test]
    public void An_anonymous_route_is_rejected() =>
        Assert.That(
            RouteErrors(new RouteConfig { RouteId = "orders", AuthorizationPolicy = "anonymous", Match = new RouteMatch { Path = "/api/orders/{**rest}" } }),
            Has.One.Message.Contains("anonymous"));

    [Test]
    public void The_gateway_does_not_start_with_a_cluster_without_a_scope()
    {
        using var gateway = new GatewayFactory(new Dictionary<string, string?> { ["ReverseProxy:Clusters:invoices-api:Metadata:Scope"] = "" });

        Assert.That(() => gateway.CreateClient(), Throws.InstanceOf<Exception>());
    }

    [TestCase("*")]
    [TestCase("https://*.example.com")]
    [TestCase("https://orders.example.com/app")]
    public void The_gateway_does_not_start_with_a_wildcard_or_path_as_cors_origin(string origin)
    {
        using var gateway = new GatewayFactory(new Dictionary<string, string?> { ["Cors:AllowedOrigins:0"] = origin });

        Assert.That(() => gateway.CreateClient(), Throws.InvalidOperationException.With.Message.Contains("CORS origin"));
    }

    [Test]
    public void The_token_source_is_one_instance_so_its_token_cache_lives_as_long_as_the_gateway()
    {
        var services = new ServiceCollection();
        services.AddOnBehalfOfTokens(new ConfigurationBuilder().Build());

        var descriptor = services.Single(service => service.ServiceType == typeof(IOnBehalfOfTokenSource));

        Assert.That(descriptor.Lifetime, Is.EqualTo(ServiceLifetime.Singleton));
    }

    private static IList<Exception> ClusterErrors(Dictionary<string, string>? metadata)
    {
        var context = new TransformClusterValidationContext
        {
            Services = new ServiceCollection().BuildServiceProvider(),
            Cluster = new ClusterConfig { ClusterId = "orders-api", Metadata = metadata },
        };
        Provider.ValidateCluster(context);
        return context.Errors;
    }

    private static IList<Exception> RouteErrors(RouteConfig route)
    {
        var context = new TransformRouteValidationContext
        {
            Services = new ServiceCollection().BuildServiceProvider(),
            Route = route with { ClusterId = "orders-api" },
        };
        Provider.ValidateRoute(context);
        return context.Errors;
    }
}
