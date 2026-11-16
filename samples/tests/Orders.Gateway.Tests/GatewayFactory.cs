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
using Orders.Gateway.Downstream;
using Yarp.ReverseProxy.Forwarder;

namespace Orders.Gateway.Tests;

/// <summary>
/// The real gateway, with its real authentication, routes and transforms. Only the edges are
/// replaced: the signing keys, the token exchange, and the network to the APIs behind it.
/// </summary>
public sealed class GatewayFactory : WebApplicationFactory<Program>
{
    public const string OrdersScope = "api://orders/access_as_user";
    public const string InvoicesScope = "api://invoices/access_as_user";
    public const string SpaOrigin = "http://localhost:5173";

    private readonly Dictionary<string, string?> _settings = new()
    {
        ["EntraId:Instance"] = TestTokens.Instance,
        ["EntraId:TenantId"] = TestTokens.TenantId,
        ["EntraId:ClientId"] = TestTokens.GatewayClientId,
        ["Cors:AllowedOrigins:0"] = SpaOrigin,
        ["ReverseProxy:Clusters:orders-api:Metadata:Scope"] = OrdersScope,
        ["ReverseProxy:Clusters:orders-api:Destinations:primary:Address"] = "https://orders.test/",
        ["ReverseProxy:Clusters:invoices-api:Metadata:Scope"] = InvoicesScope,
        ["ReverseProxy:Clusters:invoices-api:Destinations:primary:Address"] = "https://invoices.test/",
    };

    public GatewayFactory(IReadOnlyDictionary<string, string?>? overrides = null)
    {
        foreach (var (key, value) in overrides ?? new Dictionary<string, string?>())
        {
            _settings[key] = value;
        }
    }

    public FakeOnBehalfOfTokenSource TokenSource { get; } = new();
    public RecordingHandler Apis { get; } = new();

    protected override void ConfigureWebHost(IWebHostBuilder builder)
    {
        builder.UseEnvironment("Testing");
        foreach (var (key, value) in _settings)
        {
            builder.UseSetting(key, value);
        }

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

            services.RemoveAll<IForwarderHttpClientFactory>();
            services.AddSingleton<IForwarderHttpClientFactory>(new RecordingForwarderClientFactory(Apis));
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

public sealed record Exchange(string IncomingToken, string Scope);

public sealed class FakeOnBehalfOfTokenSource : IOnBehalfOfTokenSource
{
    public ConcurrentQueue<Exchange> Exchanges { get; } = new();

    /// <summary>Throw from here to simulate Entra ID refusing the exchange.</summary>
    public Func<string, string> Exchange { get; set; } = scope => $"obo-token-for {scope}";

    public Task<string> GetTokenAsync(string incomingToken, IReadOnlyCollection<string> scopes, CancellationToken cancellationToken)
    {
        var scope = scopes.Single();
        Exchanges.Enqueue(new Exchange(incomingToken, scope));
        return Task.FromResult(Exchange(scope));
    }
}

public sealed record ForwardedRequest(Uri Uri, string? Authorization, bool HasCookie);

/// <summary>Stands in for the APIs behind the gateway: records what reaches them and answers.</summary>
public sealed class RecordingHandler : HttpMessageHandler
{
    public ConcurrentQueue<ForwardedRequest> Requests { get; } = new();

    public Func<HttpResponseMessage> Respond { get; set; } =
        () => new HttpResponseMessage(HttpStatusCode.OK) { Content = new StringContent("""{"orders":[]}""") };

    protected override Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken cancellationToken)
    {
        Requests.Enqueue(new ForwardedRequest(
            request.RequestUri!,
            request.Headers.Authorization?.ToString(),
            request.Headers.Contains("Cookie")));
        return Task.FromResult(Respond());
    }
}

public sealed class RecordingForwarderClientFactory(RecordingHandler handler) : IForwarderHttpClientFactory
{
    public HttpMessageInvoker CreateClient(ForwarderHttpClientContext context) => new(handler, disposeHandler: false);
}
