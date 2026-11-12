using System.Collections.Concurrent;
using System.Net;
using System.Net.Http.Headers;
using Microsoft.AspNetCore.Authentication.JwtBearer;
using Microsoft.AspNetCore.Hosting;
using Microsoft.AspNetCore.Mvc.Testing;
using Microsoft.AspNetCore.TestHost;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.Extensions.DependencyInjection.Extensions;
using Microsoft.IdentityModel.Protocols;
using Microsoft.IdentityModel.Protocols.OpenIdConnect;
using Orders.Api.Downstream;

namespace Orders.Api.Tests;

/// <summary>
/// The real API, with the real authentication and authorization setup. Only the edges are replaced:
/// the signing keys come from <see cref="TestTokens"/> instead of the Entra ID metadata endpoint, and
/// the token exchange and the downstream API are fakes.
/// </summary>
public sealed class OrdersApiFactory : WebApplicationFactory<Program>
{
    public const string InvoicesScope = "api://invoices/access_as_user";

    public FakeOnBehalfOfTokenSource TokenSource { get; } = new();
    public RecordingHandler Invoices { get; } = new();

    protected override void ConfigureWebHost(IWebHostBuilder builder)
    {
        builder.UseEnvironment("Testing");
        builder.UseSetting("EntraId:Instance", TestTokens.Instance);
        builder.UseSetting("EntraId:TenantId", TestTokens.TenantId);
        builder.UseSetting("EntraId:ClientId", TestTokens.ApiClientId);
        builder.UseSetting("InvoicesApi:BaseAddress", "https://invoices.test/");
        builder.UseSetting("InvoicesApi:Scope", InvoicesScope);
        builder.UseSetting("APPLICATIONINSIGHTS_CONNECTION_STRING", "");

        builder.ConfigureTestServices(services =>
        {
            services.PostConfigure<JwtBearerOptions>(JwtBearerDefaults.AuthenticationScheme, options =>
            {
                var configuration = new OpenIdConnectConfiguration { Issuer = TestTokens.Issuer };
                configuration.SigningKeys.Add(TestTokens.SigningKey);

                // Both: with only Configuration set, the Authority still makes the handler fetch metadata.
                options.Configuration = configuration;
                options.ConfigurationManager = new StaticConfigurationManager<OpenIdConnectConfiguration>(configuration);
            });

            services.RemoveAll<IOnBehalfOfTokenSource>();
            services.AddSingleton<IOnBehalfOfTokenSource>(TokenSource);

            services.AddHttpClient(InvoicesApi.ClientName).ConfigurePrimaryHttpMessageHandler(() => Invoices);
        });
    }

    public HttpClient CreateClient(TestToken? token)
    {
        var client = CreateClient();
        if (token is not null)
        {
            client.DefaultRequestHeaders.Authorization = new AuthenticationHeaderValue("Bearer", token.Serialize());
        }

        return client;
    }
}

public sealed class FakeOnBehalfOfTokenSource : IOnBehalfOfTokenSource
{
    public ConcurrentQueue<string> IncomingTokens { get; } = new();

    public Task<string> GetTokenAsync(string incomingToken, IReadOnlyCollection<string> scopes, CancellationToken cancellationToken)
    {
        IncomingTokens.Enqueue(incomingToken);
        return Task.FromResult($"obo-token-for {string.Join(' ', scopes)}");
    }
}

public sealed class RecordingHandler : HttpMessageHandler
{
    public ConcurrentQueue<AuthenticationHeaderValue?> Authorizations { get; } = new();

    protected override Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken cancellationToken)
    {
        Authorizations.Enqueue(request.Headers.Authorization);
        return Task.FromResult(new HttpResponseMessage(HttpStatusCode.OK) { Content = new StringContent("""{"amount":42}""") });
    }

    // The client factory disposes handlers it no longer uses; this one is shared across the test run.
    protected override void Dispose(bool disposing)
    {
    }
}
