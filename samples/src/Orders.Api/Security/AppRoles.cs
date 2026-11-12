namespace Orders.Api.Security;

/// <summary>
/// The values of the app roles and scopes in <c>app-registrations.json</c>, in one place.
/// A role value is a contract between the definition file and the code: change it in both, or
/// nobody has access.
/// </summary>
public static class AppRoles
{
    public const string OrdersRead = "Orders.Read";
    public const string OrdersAdmin = "Orders.Admin";
    public const string OrdersProcess = "Orders.Process";
}

public static class AppScopes
{
    public const string AccessAsUser = "access_as_user";
}
