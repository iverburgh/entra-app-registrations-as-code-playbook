using Orders.Api.Downstream;
using Orders.Api.Security;

namespace Orders.Api.Endpoints;

public static class OrderEndpoints
{
    private static readonly Order[] SampleOrders = [new(1, "Placed"), new(2, "Shipped")];

    public static IEndpointRouteBuilder MapOrderEndpoints(this IEndpointRouteBuilder app)
    {
        app.MapGet("/health", () => Results.Ok("healthy"))
            .AllowAnonymousBecause("Platform health probes carry no token.");

        var orders = app.MapGroup("/orders");

        orders.MapGet("/", () => Results.Ok(SampleOrders))
            .RequireAuthorization(Policies.ReadOrders);

        orders.MapPost("/{id:int}/cancel", (int id) => Results.Ok(new Order(id, "Cancelled")))
            .RequireAuthorization(Policies.AdministerOrders);

        orders.MapPost("/{id:int}/process", (int id) => Results.Ok(new Order(id, "Processed")))
            .RequireAuthorization(Policies.ProcessOrders);

        orders.MapGet("/{id:int}/invoice", async (int id, IHttpClientFactory clients, CancellationToken cancellationToken) =>
            {
                var invoices = clients.CreateClient(InvoicesApi.ClientName);
                var invoice = await invoices.GetStringAsync($"invoices?order={id}", cancellationToken);
                return Results.Text(invoice, "application/json");
            })
            .RequireAuthorization(Policies.ReadOrders);

        return app;
    }
}

public sealed record Order(int Id, string Status);
