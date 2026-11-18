using System.Security.Claims;
using BEKP.Shared.Security;
using Microsoft.AspNetCore.Authentication;
using Microsoft.Extensions.Options;

namespace BEKP.Api.Security;

/// <summary>Windows mode: grants BEKP roles to members of the configured Active Directory groups.</summary>
public sealed class WindowsGroupRoleTransformation(IOptions<BekpAuthenticationOptions> options) : IClaimsTransformation
{
    private const string IdentityType = "BEKP.WindowsGroups";

    public Task<ClaimsPrincipal> TransformAsync(ClaimsPrincipal principal)
    {
        ArgumentNullException.ThrowIfNull(principal);
        if (principal.Identity?.IsAuthenticated != true || principal.Identities.Any(i => i.AuthenticationType == IdentityType))
        {
            return Task.FromResult(principal);
        }

        var settings = options.Value;
        var roles = new List<string>();
        AddIfMember(principal, settings.WindowsViewerGroups, BekpRoles.DashboardViewer, roles);
        AddIfMember(principal, settings.WindowsIntegrationGroups, BekpRoles.Integration, roles);
        AddIfMember(principal, settings.WindowsAdminGroups, BekpRoles.Administrator, roles);

        var identity = new ClaimsIdentity(roles.Select(r => new Claim(ClaimTypes.Role, r)), IdentityType, ClaimTypes.Name, ClaimTypes.Role);
        principal.AddIdentity(identity);
        return Task.FromResult(principal);
    }

    private static void AddIfMember(ClaimsPrincipal principal, string[] groups, string role, List<string> roles)
    {
        if (groups.Any(g => !string.IsNullOrWhiteSpace(g) && principal.IsInRole(g.Trim())))
        {
            roles.Add(role);
        }
    }
}
