using Azure.Core;
using Azure.Identity;

namespace Orders.Api.Identity;

public enum AzureIdentityKind
{
    /// <summary>Local development: the developer's own sign-in (Azure CLI, Visual Studio, ...).</summary>
    Developer,
    SystemAssigned,
    UserAssigned,
}

/// <summary>
/// Which identity the application uses to call Azure services, chosen explicitly.
/// </summary>
/// <remarks>
/// <see cref="DefaultAzureCredential"/> tries a list of credentials and takes the first that works.
/// Convenient on a laptop; in Azure it makes the identity depend on what happens to be present,
/// such as an <c>AZURE_CLIENT_ID</c> variable set for another purpose. Here, a hosted application
/// says which managed identity it uses, and the developer credential never falls back to one.
/// </remarks>
public sealed record AzureIdentity(AzureIdentityKind Kind, string? ClientId = null)
{
    public static readonly AzureIdentity Developer = new(AzureIdentityKind.Developer);

    /// <summary>
    /// Reads <c>ManagedIdentity:Type</c> (<c>SystemAssigned</c> or <c>UserAssigned</c>) and
    /// <c>ManagedIdentity:ClientId</c>. Neither set means local development.
    /// </summary>
    public static AzureIdentity FromConfiguration(IConfiguration configuration)
    {
        var type = configuration["ManagedIdentity:Type"];
        var clientId = configuration["ManagedIdentity:ClientId"];

        if (string.IsNullOrEmpty(type))
        {
            return string.IsNullOrEmpty(clientId)
                ? Developer
                : throw new InvalidOperationException(
                    "ManagedIdentity:ClientId is set without ManagedIdentity:Type. Set the type to UserAssigned.");
        }

        if (type.Equals("SystemAssigned", StringComparison.OrdinalIgnoreCase))
        {
            return string.IsNullOrEmpty(clientId)
                ? new AzureIdentity(AzureIdentityKind.SystemAssigned)
                : throw new InvalidOperationException(
                    "A system-assigned managed identity has no client ID to configure; remove ManagedIdentity:ClientId.");
        }

        if (type.Equals("UserAssigned", StringComparison.OrdinalIgnoreCase))
        {
            return UserAssigned(clientId, "ManagedIdentity:ClientId");
        }

        throw new InvalidOperationException($"ManagedIdentity:Type '{type}' is not supported. Use SystemAssigned or UserAssigned.");
    }

    /// <summary>
    /// Parses <c>APPLICATIONINSIGHTS_AUTHENTICATION_STRING</c>, the setting Azure Monitor uses to
    /// send telemetry with an Entra ID token instead of the instrumentation key:
    /// <c>Authorization=AAD</c> for the system-assigned identity, plus <c>ClientId=&lt;guid&gt;</c>
    /// for a user-assigned one. Empty returns <c>null</c>: telemetry is sent with the key in the
    /// connection string, which works only as long as local authentication is enabled on the
    /// Application Insights resource. That is the migration phase; see the documentation.
    /// </summary>
    public static AzureIdentity? FromApplicationInsightsAuthenticationString(string? value)
    {
        if (string.IsNullOrWhiteSpace(value))
        {
            return null;
        }

        var settings = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
        foreach (var entry in value.Split(';', StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries))
        {
            var parts = entry.Split('=', 2, StringSplitOptions.TrimEntries);
            if (parts.Length != 2 || parts[1].Length == 0 || !settings.TryAdd(parts[0], parts[1]))
            {
                throw new InvalidOperationException("APPLICATIONINSIGHTS_AUTHENTICATION_STRING must consist of unique key=value pairs.");
            }
        }

        var unknown = settings.Keys.Where(key => !key.Equals("Authorization", StringComparison.OrdinalIgnoreCase)
                                              && !key.Equals("ClientId", StringComparison.OrdinalIgnoreCase)).ToList();
        if (unknown.Count > 0)
        {
            throw new InvalidOperationException($"APPLICATIONINSIGHTS_AUTHENTICATION_STRING has unknown keys: {string.Join(", ", unknown)}.");
        }

        if (!settings.TryGetValue("Authorization", out var authorization) || !authorization.Equals("AAD", StringComparison.OrdinalIgnoreCase))
        {
            throw new InvalidOperationException("APPLICATIONINSIGHTS_AUTHENTICATION_STRING must contain Authorization=AAD.");
        }

        return settings.TryGetValue("ClientId", out var clientId)
            ? UserAssigned(clientId, "ClientId in APPLICATIONINSIGHTS_AUTHENTICATION_STRING")
            : new AzureIdentity(AzureIdentityKind.SystemAssigned);
    }

    public TokenCredential CreateCredential() => Kind switch
    {
        AzureIdentityKind.Developer => new DefaultAzureCredential(new DefaultAzureCredentialOptions
        {
            // Never pick up a managed identity or environment variables by accident.
            ExcludeManagedIdentityCredential = true,
            ExcludeEnvironmentCredential = true,
            ExcludeWorkloadIdentityCredential = true,
        }),
        AzureIdentityKind.SystemAssigned => new ManagedIdentityCredential(ManagedIdentityId.SystemAssigned),
        AzureIdentityKind.UserAssigned => new ManagedIdentityCredential(ManagedIdentityId.FromUserAssignedClientId(ClientId!)),
        _ => throw new InvalidOperationException($"Unknown identity kind {Kind}."),
    };

    private static AzureIdentity UserAssigned(string? clientId, string setting) =>
        Guid.TryParse(clientId, out var parsed)
            ? new AzureIdentity(AzureIdentityKind.UserAssigned, parsed.ToString())
            : throw new InvalidOperationException($"{setting} must be the client ID (a GUID) of a user-assigned managed identity.");
}
