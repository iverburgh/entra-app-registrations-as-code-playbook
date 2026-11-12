namespace Orders.Api.Downstream;

/// <summary>
/// Exchanges the token a user sent to this API for a token to another API, on their behalf.
/// </summary>
public interface IOnBehalfOfTokenSource
{
    Task<string> GetTokenAsync(string incomingToken, IReadOnlyCollection<string> scopes, CancellationToken cancellationToken);
}
