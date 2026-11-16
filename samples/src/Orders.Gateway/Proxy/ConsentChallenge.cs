using System.Text;

namespace Orders.Gateway.Proxy;

/// <summary>
/// The <c>WWW-Authenticate</c> value that tells the SPA the user has to act before the call can work.
/// </summary>
/// <remarks>
/// The SPA reacts to <c>error</c> by acquiring a token for <c>scope</c> interactively, passing
/// <c>claims</c> (base64-decoded) when present. A 401 without these parameters is not a reason to
/// sign in again; treating every 401 that way is how a SPA ends up in a redirect loop.
/// </remarks>
public static class ConsentChallenge
{
    public const string InteractionRequired = "interaction_required";
    public const string InsufficientClaims = "insufficient_claims";

    /// <param name="scope">The gateway scope the SPA asks for again.</param>
    /// <param name="claims">The claims challenge from Entra ID, such as a demand for multi-factor authentication.</param>
    public static string Header(string scope, string? claims) =>
        string.IsNullOrEmpty(claims)
            ? $"Bearer error=\"{InteractionRequired}\", scope=\"{scope}\""
            : $"Bearer error=\"{InsufficientClaims}\", claims=\"{Convert.ToBase64String(Encoding.UTF8.GetBytes(claims))}\", scope=\"{scope}\"";
}
