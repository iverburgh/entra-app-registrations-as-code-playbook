using System.Text;
using Microsoft.AspNetCore.Http;
using Orders.Gateway.Proxy;

namespace Orders.Gateway.Tests;

public sealed class ConsentChallengeTests
{
    private const string Scope = "api://gateway/.default";

    [Test]
    public void Without_claims_it_asks_for_interaction() =>
        Assert.That(ConsentChallenge.Header(Scope, claims: null),
            Is.EqualTo("Bearer error=\"interaction_required\", scope=\"api://gateway/.default\""));

    [Test]
    public void With_a_claims_challenge_it_passes_the_claims_on_base64_encoded()
    {
        const string claims = """{"access_token":{"acrs":{"essential":true,"value":"c1"}}}""";

        var header = ConsentChallenge.Header(Scope, claims);

        var encoded = Convert.ToBase64String(Encoding.UTF8.GetBytes(claims));
        Assert.That(header, Is.EqualTo($"Bearer error=\"insufficient_claims\", claims=\"{encoded}\", scope=\"api://gateway/.default\""));
    }

    [Test]
    public void Writing_the_challenge_sets_401_and_the_header()
    {
        var context = new DefaultHttpContext();

        OnBehalfOfTransformProvider.WriteChallenge(context.Response, Scope, claims: null);

        Assert.That(context.Response.StatusCode, Is.EqualTo(StatusCodes.Status401Unauthorized));
        Assert.That(context.Response.Headers.WWWAuthenticate.ToString(), Does.StartWith("Bearer error=\"interaction_required\""));
    }
}
