using System.Net;
using Microsoft.AspNetCore.Authentication;
using Microsoft.Extensions.Options;
using Microsoft.Identity.Client;
using Orders.Gateway.Downstream;
using Orders.Gateway.Security;
using Yarp.ReverseProxy.Transforms;
using Yarp.ReverseProxy.Transforms.Builder;

namespace Orders.Gateway.Proxy;

/// <summary>
/// Replaces the SPA's token with a token for the API behind the route, obtained on behalf of the
/// same user, on every proxied request.
/// </summary>
/// <remarks>
/// The downstream scope is metadata of the cluster: the API decides which token it needs, so every
/// route to the same API gets the same scope. The user's own token never leaves the gateway, and
/// neither do cookies sent to the gateway's origin.
/// </remarks>
public sealed class OnBehalfOfTransformProvider(
    IOptions<EntraIdOptions> entraId,
    ILogger<OnBehalfOfTransformProvider> logger) : ITransformProvider
{
    /// <summary>The cluster metadata key with the scope to request, such as <c>api://&lt;app-id&gt;/access_as_user</c>.</summary>
    public const string ScopeMetadataKey = "Scope";

    public void ValidateRoute(TransformRouteValidationContext context)
    {
        var route = context.Route;
        var prefix = RoutePaths.LiteralPrefix(route.Match.Path);
        if (prefix.Length == 0)
        {
            context.Errors.Add(new InvalidOperationException(
                $"Route '{route.RouteId}' must start with a literal path such as /api/orders; a catch-all route would send every path to one API with a token for it."));
        }

        if (string.Equals(route.AuthorizationPolicy, "Anonymous", StringComparison.OrdinalIgnoreCase))
        {
            context.Errors.Add(new InvalidOperationException(
                $"Route '{route.RouteId}' is anonymous; without a user there is nobody to call the API on behalf of."));
        }
    }

    public void ValidateCluster(TransformClusterValidationContext context)
    {
        var cluster = context.Cluster;
        if (!IsScope(GetScope(cluster.Metadata)))
        {
            context.Errors.Add(new InvalidOperationException(
                $"Cluster '{cluster.ClusterId}' needs metadata '{ScopeMetadataKey}' with the scope of its API, such as api://<application-id>/access_as_user."));
        }
    }

    public void Apply(TransformBuilderContext context)
    {
        var scope = GetScope(context.Cluster?.Metadata);
        var routeId = context.Route.RouteId;

        context.AddRequestTransform(transform => ExchangeTokenAsync(transform, scope, routeId));
        context.AddResponseTransform(HideDownstreamUnauthorized);
    }

    private async ValueTask ExchangeTokenAsync(RequestTransformContext transform, string? scope, string routeId)
    {
        // First, whatever happens next: the request to the API carries no credential of the user's own.
        transform.ProxyRequest.Headers.Authorization = null;
        transform.ProxyRequest.Headers.Remove("Cookie");

        var http = transform.HttpContext;
        if (!IsScope(scope))
        {
            logger.LogError("Route {RouteId} has no downstream scope; the request is not forwarded.", routeId);
            http.Response.StatusCode = StatusCodes.Status500InternalServerError;
            return;
        }

        var incoming = http.User.Identity?.IsAuthenticated == true ? await http.GetTokenAsync("access_token") : null;
        if (string.IsNullOrEmpty(incoming))
        {
            http.Response.StatusCode = StatusCodes.Status401Unauthorized;
            return;
        }

        // Transform providers are singletons; resolving per request also works for a scoped token
        // service, such as ITokenAcquisition of Microsoft.Identity.Web.
        var tokens = http.RequestServices.GetRequiredService<IOnBehalfOfTokenSource>();
        try
        {
            var token = await tokens.GetTokenAsync(incoming, [scope!], http.RequestAborted);
            transform.ProxyRequest.Headers.Authorization = new("Bearer", token);
        }
        catch (MsalUiRequiredException exception)
        {
            logger.LogInformation("The user has to act before route {RouteId} can be called: {ErrorCode}.", routeId, exception.ErrorCode);
            WriteChallenge(http.Response, entraId.Value.ChallengeScope, exception.Claims);
        }
        catch (MsalException exception)
        {
            // A configuration problem of the gateway (credential, scope, consent of the tenant), not
            // something the user can fix by signing in again.
            logger.LogError(exception, "The on-behalf-of exchange for route {RouteId} failed: {ErrorCode}.", routeId, exception.ErrorCode);
            http.Response.StatusCode = StatusCodes.Status502BadGateway;
        }
    }

    /// <summary>Sets the 401 that makes the SPA ask the user for consent, MFA or a new sign-in.</summary>
    public static void WriteChallenge(HttpResponse response, string scope, string? claims)
    {
        response.StatusCode = StatusCodes.Status401Unauthorized;
        response.Headers.WWWAuthenticate = ConsentChallenge.Header(scope, claims);
    }

    private ValueTask HideDownstreamUnauthorized(ResponseTransformContext transform)
    {
        // A 401 from the API means the gateway sent a token the API does not accept: a configuration
        // problem between the two. Passed on, the SPA would read it as "sign in again" and loop.
        // A 403 is passed on unchanged: the user is known, and not allowed.
        if (transform.ProxyResponse?.StatusCode == HttpStatusCode.Unauthorized)
        {
            logger.LogError("The API behind {Path} rejected the on-behalf-of token.", transform.HttpContext.Request.Path);
            transform.HttpContext.Response.StatusCode = StatusCodes.Status502BadGateway;
            transform.HttpContext.Response.Headers.Remove("WWW-Authenticate");
            transform.SuppressResponseBody = true;
        }

        return ValueTask.CompletedTask;
    }

    private static string? GetScope(IReadOnlyDictionary<string, string>? metadata) =>
        metadata is not null && metadata.TryGetValue(ScopeMetadataKey, out var scope) ? scope : null;

    private static bool IsScope(string? scope) =>
        Uri.TryCreate(scope, UriKind.Absolute, out var uri)
        && (uri.Scheme == "api" || uri.Scheme == Uri.UriSchemeHttps)
        && uri.AbsolutePath.Trim('/').Length > 0;
}
