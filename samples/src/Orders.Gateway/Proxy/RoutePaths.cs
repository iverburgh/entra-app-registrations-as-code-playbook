namespace Orders.Gateway.Proxy;

/// <summary>Compares request paths with the literal start of a route pattern such as <c>/api/orders/{**rest}</c>.</summary>
public static class RoutePaths
{
    /// <summary>The part of the pattern before its first parameter, without a trailing slash: <c>/api/orders</c>.</summary>
    public static string LiteralPrefix(string? pattern)
    {
        if (string.IsNullOrEmpty(pattern))
        {
            return "";
        }

        var parameter = pattern.IndexOf('{', StringComparison.Ordinal);
        var literal = parameter < 0 ? pattern : pattern[..parameter];
        return literal.TrimEnd('/');
    }

    /// <summary>
    /// Whether the path is the prefix itself or below it, at a segment boundary: <c>/api/orders</c>
    /// covers <c>/api/orders/42</c>, not <c>/api/orders-admin</c>. An empty prefix covers nothing.
    /// </summary>
    public static bool Covers(string prefix, PathString path)
    {
        if (prefix.Length == 0 || !path.HasValue)
        {
            return false;
        }

        var value = path.Value!;
        return value.Equals(prefix, StringComparison.OrdinalIgnoreCase)
            || (value.StartsWith(prefix, StringComparison.OrdinalIgnoreCase) && value[prefix.Length] == '/');
    }
}
