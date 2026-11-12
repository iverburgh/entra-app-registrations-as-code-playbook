using Microsoft.AspNetCore.Authorization;
using Microsoft.AspNetCore.Http;
using Microsoft.AspNetCore.Routing;
using Microsoft.AspNetCore.Routing.Patterns;
using Microsoft.Extensions.DependencyInjection;
using Orders.Api.Security;

namespace Orders.Api.Tests;

/// <summary>
/// Every endpoint names who may call it, or says why anyone may. The fallback policy only requires
/// a signed-in user; an endpoint that relies on it is open to every account in the tenant, and to
/// every application that can get a token for this API.
/// </summary>
public sealed class EndpointConventionTests
{
    [Test]
    public void Every_endpoint_requires_a_policy_or_is_anonymous_for_a_stated_reason()
    {
        using var factory = new OrdersApiFactory();
        var endpoints = factory.Services.GetRequiredService<EndpointDataSource>().Endpoints.OfType<RouteEndpoint>().ToList();

        var violations = endpoints.Select(Violation).OfType<string>().ToList();

        Assert.Multiple(() =>
        {
            Assert.That(endpoints, Is.Not.Empty, "No endpoints found: the test would pass without checking anything.");
            Assert.That(violations, Is.Empty);
        });
    }

    [Test]
    public void The_convention_catches_an_endpoint_that_relies_on_the_fallback_policy()
    {
        var endpoint = Endpoint("/unprotected");

        Assert.That(Violation(endpoint), Does.Contain("/unprotected"));
    }

    [Test]
    public void The_convention_catches_an_anonymous_endpoint_without_a_reason()
    {
        var endpoint = Endpoint("/open", new AllowAnonymousAttribute());

        Assert.That(Violation(endpoint), Does.Contain("/open"));
    }

    [Test]
    public void The_convention_does_not_count_a_bare_authorize_as_a_policy()
    {
        var endpoint = Endpoint("/any-user", new AuthorizeAttribute());

        Assert.That(Violation(endpoint), Does.Contain("/any-user"));
    }

    private static string? Violation(RouteEndpoint endpoint)
    {
        var name = $"{string.Join(",", endpoint.Metadata.GetMetadata<IHttpMethodMetadata>()?.HttpMethods ?? [])} {endpoint.RoutePattern.RawText}";

        if (endpoint.Metadata.GetMetadata<IAllowAnonymous>() is not null)
        {
            return string.IsNullOrWhiteSpace(endpoint.Metadata.GetMetadata<AnonymousBecauseAttribute>()?.Reason)
                ? $"{name} allows anonymous access without a reason; use AllowAnonymousBecause(\"...\")."
                : null;
        }

        var namesWhoMayCall = endpoint.Metadata.GetOrderedMetadata<IAuthorizeData>()
            .Any(data => !string.IsNullOrWhiteSpace(data.Policy) || !string.IsNullOrWhiteSpace(data.Roles));

        return namesWhoMayCall ? null : $"{name} names no policy or role, so any signed-in caller may use it.";
    }

    private static RouteEndpoint Endpoint(string pattern, params object[] metadata) =>
        new(_ => Task.CompletedTask, RoutePatternFactory.Parse(pattern), order: 0, new EndpointMetadataCollection(metadata), pattern);
}
