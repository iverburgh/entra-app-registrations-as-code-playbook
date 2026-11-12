using System.ComponentModel.DataAnnotations;
using Microsoft.Extensions.Options;

namespace Orders.Api.Downstream;

public sealed class InvoicesApiOptions
{
    public const string Section = "InvoicesApi";

    [Required]
    public Uri? BaseAddress { get; set; }

    /// <summary>A delegated scope of the invoices API, such as <c>api://&lt;appId&gt;/access_as_user</c>.</summary>
    [Required]
    public string Scope { get; set; } = "";
}

public static class InvoicesApi
{
    public const string ClientName = "invoices";

    public static IServiceCollection AddInvoicesApi(this IServiceCollection services, IConfiguration configuration)
    {
        services.AddOptions<InvoicesApiOptions>()
            .Bind(configuration.GetSection(InvoicesApiOptions.Section))
            .ValidateDataAnnotations();
        services.AddOptions<OnBehalfOfOptions>()
            .Bind(configuration.GetSection(OnBehalfOfOptions.Section))
            .ValidateDataAnnotations();

        services.AddHttpContextAccessor();
        services.AddSingleton<IOnBehalfOfTokenSource, MsalOnBehalfOfTokenSource>();

        services.AddHttpClient(ClientName, (provider, client) =>
                client.BaseAddress = provider.GetRequiredService<IOptions<InvoicesApiOptions>>().Value.BaseAddress)
            .AddHttpMessageHandler(provider => new OnBehalfOfHandler(
                provider.GetRequiredService<IHttpContextAccessor>(),
                provider.GetRequiredService<IOnBehalfOfTokenSource>(),
                provider.GetRequiredService<IOptions<InvoicesApiOptions>>().Value.Scope));

        return services;
    }
}
