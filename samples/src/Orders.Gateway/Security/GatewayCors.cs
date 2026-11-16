namespace Orders.Gateway.Security;

public sealed class CorsOptions
{
    public const string Section = "Cors";

    /// <summary>
    /// Origins of a SPA served from somewhere other than the gateway, such as a local development
    /// server. Empty, the recommended setup, means the SPA and the gateway share an origin and the
    /// browser needs no CORS at all.
    /// </summary>
    public string[] AllowedOrigins { get; set; } = [];
}

public static class GatewayCors
{
    public static IServiceCollection AddGatewayCors(this IServiceCollection services, IConfiguration configuration)
    {
        var configured = configuration.GetSection(CorsOptions.Section).Get<CorsOptions>()?.AllowedOrigins ?? [];
        var origins = new List<string>();
        foreach (var origin in configured)
        {
            if (origin.Contains('*', StringComparison.Ordinal)
                || !Uri.TryCreate(origin, UriKind.Absolute, out var uri)
                || uri.AbsolutePath != "/")
            {
                throw new InvalidOperationException(
                    $"CORS origin '{origin}' must be one exact origin, such as https://orders.example.com, without wildcards or a path.");
            }

            // The browser sends the origin without a trailing slash; a configured slash would never match.
            origins.Add(uri.GetLeftPart(UriPartial.Authority));
        }

        services.AddCors(options => options.AddDefaultPolicy(policy => policy
            .WithOrigins([.. origins])
            .WithMethods("GET", "POST", "PUT", "PATCH", "DELETE")
            .WithHeaders("Authorization", "Content-Type")

            // Without this, script on another origin cannot read the consent challenge.
            .WithExposedHeaders("WWW-Authenticate")));

        return services;
    }
}
