using System.Security.Claims;
using Microsoft.AspNetCore.Authorization;

namespace Orders.Api.Security;

/// <summary>
/// Named authorization policies. Every endpoint names one of these, or is explicitly anonymous.
/// </summary>
public static class Policies
{
    public const string ReadOrders = nameof(ReadOrders);
    public const string AdministerOrders = nameof(AdministerOrders);
    public const string ProcessOrders = nameof(ProcessOrders);

    public static void Configure(AuthorizationOptions options)
    {
        // Applies only to endpoints that declare nothing. It guarantees "not anonymous", not "allowed":
        // any signed-in user of the tenant passes it. The convention test makes sure no endpoint relies on it.
        options.FallbackPolicy = new AuthorizationPolicyBuilder()
            .RequireAuthenticatedUser()
            .Build();

        options.AddPolicy(ReadOrders, policy => policy
            .RequireAuthenticatedUser()
            .RequireAssertion(context => IsUserWithRole(context.User, AppRoles.OrdersRead, AppRoles.OrdersAdmin)));

        options.AddPolicy(AdministerOrders, policy => policy
            .RequireAuthenticatedUser()
            .RequireAssertion(context => IsUserWithRole(context.User, AppRoles.OrdersAdmin)));

        options.AddPolicy(ProcessOrders, policy => policy
            .RequireAuthenticatedUser()
            .RequireAssertion(context => IsApplicationWithRole(context.User, AppRoles.OrdersProcess)));
    }

    /// <summary>
    /// A user, through an application acting on their behalf: a delegated token. It must carry the
    /// scope the application was consented for, and the user's role.
    /// </summary>
    private static bool IsUserWithRole(ClaimsPrincipal user, params string[] roles) =>
        user.IsDelegated() && user.HasScope(AppScopes.AccessAsUser) && roles.Any(user.IsInRole);

    /// <summary>
    /// An application acting as itself: an app-only token. It carries roles, never scopes.
    /// </summary>
    private static bool IsApplicationWithRole(ClaimsPrincipal user, params string[] roles) =>
        !user.IsDelegated() && roles.Any(user.IsInRole);
}

public static class ClaimsPrincipalExtensions
{
    /// <summary>Delegated tokens have an <c>scp</c> claim; app-only tokens do not.</summary>
    public static bool IsDelegated(this ClaimsPrincipal user) => user.HasClaim(claim => claim.Type == "scp");

    /// <summary><c>scp</c> is one claim with the scopes separated by spaces.</summary>
    public static bool HasScope(this ClaimsPrincipal user, string scope) =>
        user.FindAll("scp")
            .SelectMany(claim => claim.Value.Split(' ', StringSplitOptions.RemoveEmptyEntries))
            .Contains(scope, StringComparer.Ordinal);
}
