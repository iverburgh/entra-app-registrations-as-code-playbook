using System.Security.Cryptography;
using Microsoft.IdentityModel.JsonWebTokens;
using Microsoft.IdentityModel.Tokens;
using Orders.Api.Security;

namespace Orders.Api.Tests;

/// <summary>
/// Plays the part of Entra ID: issues tokens signed with a key the API under test trusts.
/// Identifiers are generated per test run, so no tenant or application ID appears in the tests.
/// </summary>
public static class TestTokens
{
    public const string Instance = "https://login.microsoftonline.com/";

    public static readonly string TenantId = Guid.NewGuid().ToString();
    public static readonly string ApiClientId = Guid.NewGuid().ToString();
    public static readonly string Issuer = $"{Instance.TrimEnd('/')}/{TenantId}/v2.0";

    public static readonly RsaSecurityKey SigningKey = new(RSA.Create(2048)) { KeyId = "trusted" };
    public static readonly RsaSecurityKey UntrustedKey = new(RSA.Create(2048)) { KeyId = "untrusted" };

    /// <summary>A user, signed in to a client application that calls this API on their behalf.</summary>
    public static TestToken User(params string[] roles) =>
        new() { Scope = AppScopes.AccessAsUser, Roles = roles };

    /// <summary>An application calling as itself, with application permissions (app roles).</summary>
    public static TestToken Application(params string[] roles) =>
        new() { Scope = null, Roles = roles };
}

public sealed record TestToken
{
    public string? Scope { get; init; }
    public IReadOnlyList<string> Roles { get; init; } = [];
    public string Issuer { get; init; } = TestTokens.Issuer;
    public string Audience { get; init; } = TestTokens.ApiClientId;
    public DateTime Expires { get; init; } = DateTime.UtcNow.AddHours(1);
    public SecurityKey Key { get; init; } = TestTokens.SigningKey;

    public string Serialize()
    {
        var claims = new Dictionary<string, object>
        {
            ["oid"] = Guid.NewGuid().ToString(),
            ["tid"] = TestTokens.TenantId,
            ["azp"] = Guid.NewGuid().ToString(),
            ["ver"] = "2.0",
        };

        if (Scope is not null)
        {
            claims["scp"] = Scope;
            claims["name"] = "Test User";
        }

        if (Roles.Count > 0)
        {
            claims["roles"] = Roles.ToArray();
        }

        return new JsonWebTokenHandler().CreateToken(new SecurityTokenDescriptor
        {
            Issuer = Issuer,
            Audience = Audience,
            IssuedAt = Expires.AddHours(-1),
            NotBefore = Expires.AddHours(-1),
            Expires = Expires,
            Claims = claims,
            SigningCredentials = new SigningCredentials(Key, SecurityAlgorithms.RsaSha256),
        });
    }

    public override string ToString() =>
        $"{(Scope is null ? "application" : $"user (scp '{Scope}')")} with roles [{string.Join(", ", Roles)}]";
}
