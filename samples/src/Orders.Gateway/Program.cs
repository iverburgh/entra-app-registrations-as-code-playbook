using Azure.Core;
using Orders.Api.Identity;
using Orders.Gateway.Downstream;
using Orders.Gateway.Proxy;
using Orders.Gateway.Security;

var builder = WebApplication.CreateBuilder(args);

var identity = AzureIdentity.FromConfiguration(builder.Configuration);
builder.Services.AddSingleton<TokenCredential>(_ => identity.CreateCredential());

builder.Services.AddGatewayAuthentication(builder.Configuration);
builder.Services.AddGatewayCors(builder.Configuration);
builder.Services.AddOnBehalfOfTokens(builder.Configuration);

// Only "is this process up": no calls to the APIs behind the gateway, which would need a user.
builder.Services.AddHealthChecks();

builder.Services.AddReverseProxy()
    .LoadFromConfig(builder.Configuration.GetSection("ReverseProxy"))
    .AddTransforms<OnBehalfOfTransformProvider>();

var app = builder.Build();

// Before authentication: a CORS preflight carries no token and must not be challenged.
app.UseCors();
app.UseAuthentication();
app.UseAuthorization();

// The target of the load balancer's health probe. Anonymous on purpose, and tested to stay that
// way: a probe on an authenticated path takes the whole gateway out of rotation.
app.MapHealthChecks("/health").AllowAnonymous();

app.MapReverseProxy();

app.Run();

public partial class Program;
