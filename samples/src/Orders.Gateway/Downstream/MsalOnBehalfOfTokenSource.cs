using System.ComponentModel.DataAnnotations;
using System.Security.Cryptography.X509Certificates;
using Azure.Core;
using Azure.Security.KeyVault.Secrets;
using Microsoft.Extensions.Options;
using Microsoft.Identity.Client;
using Orders.Gateway.Security;

namespace Orders.Gateway.Downstream;

public sealed class OnBehalfOfOptions
{
    public const string Section = "OnBehalfOf";

    /// <summary>The vault that holds the gateway's certificate, created by the app registration script.</summary>
    [Required]
    public Uri? KeyVaultUri { get; set; }

    /// <summary><c>AppReg-&lt;displayName&gt;</c>, the name the app registration script gives it.</summary>
    [Required]
    public string CertificateName { get; set; } = "";
}

/// <summary>
/// The on-behalf-of exchange with MSAL, authenticating the gateway with its certificate from Key Vault.
/// </summary>
/// <remarks>
/// One instance for the whole gateway, so one token cache: MSAL keys the cached tokens by the
/// incoming token and the scopes, and a route called twice in an hour asks Entra ID once. A
/// confidential client per request would exchange the token on every proxied call. The cache is in
/// memory, per instance; behind several instances each keeps its own, which costs one exchange per
/// instance per user and API.
/// </remarks>
public sealed class MsalOnBehalfOfTokenSource(
    IOptions<EntraIdOptions> entraId,
    IOptions<OnBehalfOfOptions> options,
    TokenCredential credential) : IOnBehalfOfTokenSource, IDisposable
{
    private readonly SemaphoreSlim _lock = new(1, 1);
    private IConfidentialClientApplication? _application;

    public async Task<string> GetTokenAsync(string incomingToken, IReadOnlyCollection<string> scopes, CancellationToken cancellationToken)
    {
        var application = await GetApplicationAsync(cancellationToken);
        var result = await application
            .AcquireTokenOnBehalfOf(scopes, new UserAssertion(incomingToken))
            .ExecuteAsync(cancellationToken);
        return result.AccessToken;
    }

    public void Dispose() => _lock.Dispose();

    private async Task<IConfidentialClientApplication> GetApplicationAsync(CancellationToken cancellationToken)
    {
        if (_application is not null)
        {
            return _application;
        }

        await _lock.WaitAsync(cancellationToken);
        try
        {
            if (_application is null)
            {
                // The private key of a Key Vault certificate is read through the secret of the same
                // name, as PKCS#12. The gateway's identity needs "Key Vault Secrets User".
                var secrets = new SecretClient(options.Value.KeyVaultUri, credential);
                KeyVaultSecret secret = await secrets.GetSecretAsync(options.Value.CertificateName, cancellationToken: cancellationToken);
                var certificate = X509CertificateLoader.LoadPkcs12(Convert.FromBase64String(secret.Value), password: null);

                _application = ConfidentialClientApplicationBuilder
                    .Create(entraId.Value.ClientId)
                    .WithAuthority(entraId.Value.Instance, entraId.Value.TenantId)
                    .WithCertificate(certificate, sendX5C: true)
                    .Build();
            }

            return _application;
        }
        finally
        {
            _lock.Release();
        }
    }
}

public static class OnBehalfOfSetup
{
    public static IServiceCollection AddOnBehalfOfTokens(this IServiceCollection services, IConfiguration configuration)
    {
        services.AddOptions<OnBehalfOfOptions>()
            .Bind(configuration.GetSection(OnBehalfOfOptions.Section))
            .ValidateDataAnnotations()
            .ValidateOnStart();

        services.AddSingleton<IOnBehalfOfTokenSource, MsalOnBehalfOfTokenSource>();
        return services;
    }
}
