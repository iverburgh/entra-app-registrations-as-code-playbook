using System.Security.Cryptography;
using Microsoft.IdentityModel.JsonWebTokens;
using Microsoft.IdentityModel.Tokens;
using Orders.Gateway.Security;

namespace Orders.Gateway.Tests;

/// <summary>
/// Plays the part of Entra ID: issues tokens signed with a key the gateway under test trusts.
/// Identifiers are generated per test run, so no tenant or application ID appears in the tests.
/// </summary>
public static class TestTokens
{
    public const string Instance = "https://login.microsoftonline.com/";

    public static readonly string TenantId = Guid.NewGuid().ToString();
    public static readonly string GatewayClientId = Guid.NewGuid().ToString();
    public static readonly string Issuer = $"{Instance.TrimEnd('/')}/{TenantId}/v2.0";

    public static readonly RsaSecurityKey SigningKey = new(RSA.Create(2048)) { KeyId = "trusted" };

    /// <summary>A user signed in to the SPA, with a token for the gateway.</summary>
    public static TestToken User() => new();
}

public sealed record TestToken
{
    public string? Scope { get; init; } = GatewayScopes.AccessAsUser;
    public string Audience { get; init; } = TestTokens.GatewayClientId;

    public string Serialize()
    {
        var claims = new Dictionary<string, object>
        {
            ["oid"] = Guid.NewGuid().ToString(),
            ["tid"] = TestTokens.TenantId,
            ["azp"] = Guid.NewGuid().ToString(),
            ["ver"] = "2.0",
            ["name"] = "Test User",
        };

        if (Scope is not null)
        {
            claims["scp"] = Scope;
        }

        var now = DateTime.UtcNow;
        return new JsonWebTokenHandler().CreateToken(new SecurityTokenDescriptor
        {
            Issuer = TestTokens.Issuer,
            Audience = Audience,
            IssuedAt = now,
            NotBefore = now,
            Expires = now.AddHours(1),
            Claims = claims,
            SigningCredentials = new SigningCredentials(TestTokens.SigningKey, SecurityAlgorithms.RsaSha256),
        });
    }
}
