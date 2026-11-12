using System.Security.Claims;
using Microsoft.AspNetCore.Http;
using Orders.Api.Downstream;
using Orders.Api.Security;

namespace Orders.Api.Tests;

public sealed class OnBehalfOfTests
{
    [Test]
    public async Task The_downstream_api_gets_a_token_for_itself_not_the_token_sent_to_this_api()
    {
        using var factory = new OrdersApiFactory();
        var incoming = TestTokens.User(AppRoles.OrdersRead);
        using var client = factory.CreateClient(incoming);

        using var response = await client.GetAsync("/orders/7/invoice");

        var sentToThisApi = client.DefaultRequestHeaders.Authorization!.Parameter;
        Assert.Multiple(() =>
        {
            Assert.That(response.IsSuccessStatusCode, Is.True);
            Assert.That(factory.TokenSource.IncomingTokens, Is.EqualTo(new[] { sentToThisApi }), "The exchange starts from the user's token.");
            Assert.That(factory.Invoices.Authorizations.Select(header => header?.ToString()),
                Is.EqualTo(new[] { $"Bearer obo-token-for {OrdersApiFactory.InvoicesScope}" }),
                "The downstream API gets the exchanged token, for its own scope.");
        });
    }

    [Test]
    public void A_call_outside_a_request_fails()
    {
        using var invoker = Invoker(new HttpContextAccessor());

        Assert.ThrowsAsync<InvalidOperationException>(() => Send(invoker));
    }

    [Test]
    public void A_call_for_an_anonymous_request_fails()
    {
        var accessor = new HttpContextAccessor { HttpContext = new DefaultHttpContext { User = new ClaimsPrincipal(new ClaimsIdentity()) } };
        using var invoker = Invoker(accessor);

        Assert.ThrowsAsync<InvalidOperationException>(() => Send(invoker));
    }

    private static HttpMessageInvoker Invoker(IHttpContextAccessor accessor) =>
        new(new OnBehalfOfHandler(accessor, new FakeOnBehalfOfTokenSource(), "api://invoices/access_as_user")
        {
            InnerHandler = new RecordingHandler(),
        });

    private static async Task Send(HttpMessageInvoker invoker)
    {
        using var request = new HttpRequestMessage(HttpMethod.Get, "https://invoices.test/invoices");
        using var response = await invoker.SendAsync(request, CancellationToken.None);
    }
}
