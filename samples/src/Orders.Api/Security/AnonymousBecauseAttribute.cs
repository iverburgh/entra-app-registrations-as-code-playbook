using Microsoft.AspNetCore.Authorization;

namespace Orders.Api.Security;

/// <summary>
/// The reason an endpoint is open to anyone. Required next to every <see cref="AllowAnonymousAttribute"/>:
/// the convention test fails on an anonymous endpoint without one.
/// </summary>
[AttributeUsage(AttributeTargets.Class | AttributeTargets.Method)]
public sealed class AnonymousBecauseAttribute(string reason) : Attribute
{
    public string Reason { get; } = reason;
}

public static class AnonymousEndpointExtensions
{
    public static TBuilder AllowAnonymousBecause<TBuilder>(this TBuilder builder, string reason)
        where TBuilder : IEndpointConventionBuilder =>
        builder.AllowAnonymous().WithMetadata(new AnonymousBecauseAttribute(reason));
}
