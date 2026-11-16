using System.Security.Claims;
using Microsoft.Extensions.Options;
using Orders.Gateway.Proxy;
using Yarp.ReverseProxy.Configuration;

namespace Orders.Gateway.Security;

/// <summary>
/// Checks a validated token once more against what the gateway is for: the audience is exactly the
/// gateway, and the request is for a path a configured route covers.
/// </summary>
/// <remarks>
/// A gateway that exchanges tokens on behalf of the user never has a reason to accept a second
/// audience: Entra ID only exchanges a token whose audience is the gateway itself. A token for
/// another API could only be passed on unchanged, which is exactly what this gateway must not do.
/// Keeping the check here, next to the routes, makes a later "just add that audience too" fail
/// loudly in the tests instead of quietly widening what the gateway accepts.
/// </remarks>
public sealed class PathBasedTokenValidator(IProxyConfigProvider proxyConfig, IOptions<EntraIdOptions> entraId)
{
    /// <summary>The reason to reject the token, or <c>null</c> to accept it.</summary>
    public string? Validate(PathString path, ClaimsPrincipal? principal)
    {
        var audiences = principal?.FindAll("aud").Select(claim => claim.Value).ToList() ?? [];
        if (audiences.Count != 1 || !string.Equals(audiences[0], entraId.Value.ClientId, StringComparison.OrdinalIgnoreCase))
        {
            return $"The token's audience must be the gateway ({entraId.Value.ClientId}) and nothing else.";
        }

        var covered = proxyConfig.GetConfig().Routes
            .Select(route => RoutePaths.LiteralPrefix(route.Match.Path))
            .Any(prefix => RoutePaths.Covers(prefix, path));

        return covered ? null : $"No route of the gateway covers '{path}'.";
    }
}
