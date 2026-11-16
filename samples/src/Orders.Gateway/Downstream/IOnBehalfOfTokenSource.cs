namespace Orders.Gateway.Downstream;

/// <summary>
/// Exchanges the token the SPA sent to the gateway for a token to one downstream API, on behalf of
/// the same user.
/// </summary>
/// <remarks>
/// Throws <see cref="Microsoft.Identity.Client.MsalUiRequiredException"/> when the user has to do
/// something first: consent, multi-factor authentication, or sign in again.
/// </remarks>
public interface IOnBehalfOfTokenSource
{
    Task<string> GetTokenAsync(string incomingToken, IReadOnlyCollection<string> scopes, CancellationToken cancellationToken);
}
