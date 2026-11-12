using System.ComponentModel.DataAnnotations;
using System.Security.Cryptography.X509Certificates;
using Azure.Core;
using Azure.Security.KeyVault.Secrets;
using Microsoft.Extensions.Options;
using Microsoft.Identity.Client;
using Orders.Api.Security;

namespace Orders.Api.Downstream;

public sealed class OnBehalfOfOptions
{
    public const string Section = "OnBehalfOf";

    /// <summary>The vault that holds this API's certificate, created by the app registration script.</summary>
    [Required]
    public Uri? KeyVaultUri { get; set; }

    /// <summary><c>AppReg-&lt;displayName&gt;</c>, the name the app registration script gives it.</summary>
    [Required]
    public string CertificateName { get; set; } = "";
}

/// <summary>
/// The on-behalf-of exchange with MSAL, authenticating this API with its certificate from Key Vault.
/// </summary>
/// <remarks>
/// One instance for the whole application: MSAL caches the tokens it obtains in the confidential
/// client, keyed by the incoming token. A client per request would ask Entra ID for a new token on
/// every call. The cache is in memory, per instance: it is lost on restart and not shared between
/// instances, which is fine for tokens that live an hour.
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
                // name, as PKCS#12. The application's identity needs "Key Vault Secrets User".
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
