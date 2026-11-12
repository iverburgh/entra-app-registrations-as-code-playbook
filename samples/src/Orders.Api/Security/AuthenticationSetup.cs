using System.ComponentModel.DataAnnotations;
using Microsoft.AspNetCore.Authentication.JwtBearer;
using Microsoft.Extensions.Options;

namespace Orders.Api.Security;

public sealed class EntraIdOptions
{
    public const string Section = "EntraId";

    public string Instance { get; set; } = "https://login.microsoftonline.com/";

    [Required]
    public string TenantId { get; set; } = "";

    /// <summary>The application (client) ID of this API's app registration.</summary>
    [Required]
    public string ClientId { get; set; } = "";

    public string Issuer => $"{Instance.TrimEnd('/')}/{TenantId}/v2.0";
}

public static class AuthenticationSetup
{
    public static IServiceCollection AddEntraIdAuthentication(this IServiceCollection services, IConfiguration configuration)
    {
        services.AddOptions<EntraIdOptions>()
            .Bind(configuration.GetSection(EntraIdOptions.Section))
            .ValidateDataAnnotations()
            .ValidateOnStart();

        services.AddAuthentication(JwtBearerDefaults.AuthenticationScheme).AddJwtBearer();

        services.AddOptions<JwtBearerOptions>(JwtBearerDefaults.AuthenticationScheme)
            .Configure<IOptions<EntraIdOptions>>((options, entraId) =>
            {
                var entra = entraId.Value;
                options.Authority = entra.Issuer;

                // Keep the claim names of the token ("roles", "scp", "oid") instead of the long
                // legacy URIs ASP.NET Core maps them to by default.
                options.MapInboundClaims = false;

                // Lets a call on behalf of the user read the incoming token (HttpContext.GetTokenAsync).
                options.SaveToken = true;

                options.TokenValidationParameters.ValidIssuer = entra.Issuer;

                // A v2 access token has the application ID in "aud", not "api://<appId>".
                options.TokenValidationParameters.ValidAudience = entra.ClientId;

                options.TokenValidationParameters.RoleClaimType = "roles";
                options.TokenValidationParameters.NameClaimType = "name";
            });

        services.AddAuthorization(Policies.Configure);

        return services;
    }
}
