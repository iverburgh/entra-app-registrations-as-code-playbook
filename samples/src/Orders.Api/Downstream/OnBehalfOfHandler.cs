using System.Net.Http.Headers;
using Microsoft.AspNetCore.Authentication;

namespace Orders.Api.Downstream;

/// <summary>
/// Adds a token for the downstream API, obtained on behalf of the signed-in user, to every request.
/// </summary>
/// <remarks>
/// Never forward the incoming token itself: its audience is this API, and a downstream API that
/// accepts it does not validate its audience. The exchange gives a token for the downstream API,
/// with the user's identity and only the scope asked for.
/// </remarks>
public sealed class OnBehalfOfHandler(
    IHttpContextAccessor httpContextAccessor,
    IOnBehalfOfTokenSource tokenSource,
    string scope) : DelegatingHandler
{
    protected override async Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken cancellationToken)
    {
        var httpContext = httpContextAccessor.HttpContext
            ?? throw new InvalidOperationException("A call on behalf of a user can only be made while handling that user's request.");

        if (httpContext.User.Identity?.IsAuthenticated != true)
        {
            throw new InvalidOperationException("A call on behalf of a user needs a signed-in user.");
        }

        var incomingToken = await httpContext.GetTokenAsync("access_token")
            ?? throw new InvalidOperationException("The incoming token is not available. Is SaveToken enabled on the JWT bearer options?");

        var token = await tokenSource.GetTokenAsync(incomingToken, [scope], cancellationToken);
        request.Headers.Authorization = new AuthenticationHeaderValue("Bearer", token);

        return await base.SendAsync(request, cancellationToken);
    }
}
