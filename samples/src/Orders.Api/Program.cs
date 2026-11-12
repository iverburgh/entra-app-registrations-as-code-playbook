using Azure.Core;
using Azure.Monitor.OpenTelemetry.AspNetCore;
using Orders.Api.Downstream;
using Orders.Api.Endpoints;
using Orders.Api.Identity;
using Orders.Api.Security;

var builder = WebApplication.CreateBuilder(args);

// One identity for every Azure SDK client, chosen explicitly.
var identity = AzureIdentity.FromConfiguration(builder.Configuration);
builder.Services.AddSingleton(identity);
builder.Services.AddSingleton<TokenCredential>(_ => identity.CreateCredential());

builder.Services.AddEntraIdAuthentication(builder.Configuration);
builder.Services.AddInvoicesApi(builder.Configuration);

if (!string.IsNullOrEmpty(builder.Configuration["APPLICATIONINSIGHTS_CONNECTION_STRING"]))
{
    var telemetryIdentity = AzureIdentity.FromApplicationInsightsAuthenticationString(
        builder.Configuration["APPLICATIONINSIGHTS_AUTHENTICATION_STRING"]);

    builder.Services.AddOpenTelemetry().UseAzureMonitor(options =>
    {
        // Without a credential the instrumentation key in the connection string is used, which stops
        // working once local authentication is disabled on the Application Insights resource.
        if (telemetryIdentity is not null)
        {
            options.Credential = telemetryIdentity.CreateCredential();
        }
    });
}

var app = builder.Build();

app.UseAuthentication();
app.UseAuthorization();

app.MapOrderEndpoints();

app.Run();

public partial class Program;
