using System.ComponentModel.DataAnnotations;
using Microsoft.AspNetCore.Authentication.JwtBearer;
using Microsoft.AspNetCore.Authorization;
using Microsoft.Extensions.Options;

namespace Orders.Gateway.Security;

public sealed class EntraIdOptions
{
    public const string Section = "EntraId";

    public string Instance { get; set; } = "https://login.microsoftonline.com/";

    [Required]
    public string TenantId { get; set; } = "";

    /// <summary>The application (client) ID of the gateway's app registration: the audience of the SPA's token.</summary>
    [Required]
    public string ClientId { get; set; } = "";

    public string Issuer => $"{Instance.TrimEnd('/')}/{TenantId}/v2.0";

    /// <summary>
    /// What the SPA asks for again after a consent or sign-in challenge. The <c>.default</c> scope of
    /// the gateway lets one consent cover the gateway and, through its known client applications,
    /// the APIs it calls on the user's behalf.
    /// </summary>
    public string ChallengeScope => $"api://{ClientId}/.default";
}

/// <summary>The delegated permissions the gateway's app registration defines.</summary>
public static class GatewayScopes
{
    public const string AccessAsUser = "access_as_user";
}

public static class GatewayAuthentication
{
    public static IServiceCollection AddGatewayAuthentication(this IServiceCollection services, IConfiguration configuration)
    {
        services.AddOptions<EntraIdOptions>()
            .Bind(configuration.GetSection(EntraIdOptions.Section))
            .ValidateDataAnnotations()
            .ValidateOnStart();

        services.AddSingleton<PathBasedTokenValidator>();
        services.AddAuthentication(JwtBearerDefaults.AuthenticationScheme).AddJwtBearer();

        services.AddOptions<JwtBearerOptions>(JwtBearerDefaults.AuthenticationScheme)
            .Configure<IOptions<EntraIdOptions>>((options, entraId) =>
            {
                var entra = entraId.Value;
                options.Authority = entra.Issuer;
                options.MapInboundClaims = false;

                // The on-behalf-of exchange needs the incoming token (HttpContext.GetTokenAsync).
                options.SaveToken = true;

                options.TokenValidationParameters.ValidIssuer = entra.Issuer;

                // One audience: the gateway. A token for any other API is never accepted here, not
                // even to pass it on; see PathBasedTokenValidator.
                options.TokenValidationParameters.ValidAudience = entra.ClientId;
                options.TokenValidationParameters.NameClaimType = "name";

                options.Events ??= new JwtBearerEvents();
                var previous = options.Events.OnTokenValidated;
                options.Events.OnTokenValidated = async context =>
                {
                    await previous(context);
                    var validator = context.HttpContext.RequestServices.GetRequiredService<PathBasedTokenValidator>();
                    var failure = validator.Validate(context.Request.Path, context.Principal);
                    if (failure is not null)
                    {
                        context.Fail(failure);
                    }
                };
            });

        services.AddAuthorization(options =>
        {
            // Every proxied route requires a user token with the gateway's scope, unless a route
            // names another policy. An application token (no "scp") cannot be exchanged anyway.
            var accessAsUser = new AuthorizationPolicyBuilder(JwtBearerDefaults.AuthenticationScheme)
                .RequireAuthenticatedUser()
                .RequireAssertion(context => context.User.FindFirst("scp")?.Value
                    .Split(' ', StringSplitOptions.RemoveEmptyEntries)
                    .Contains(GatewayScopes.AccessAsUser) == true)
                .Build();

            options.DefaultPolicy = accessAsUser;
            options.FallbackPolicy = accessAsUser;
        });

        return services;
    }
}
