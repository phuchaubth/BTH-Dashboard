using BEKP.Shared.Security;
using Microsoft.AspNetCore.Authentication;
using Microsoft.AspNetCore.Authentication.JwtBearer;
using Microsoft.AspNetCore.Authorization;

namespace BEKP.Api.Security;

public sealed class BekpAuthenticationOptions
{
    public const string SectionName = "Authentication";

    /// <summary>
    /// "Jwt" (default, OpenID Connect provider), "Windows" (IIS Windows Authentication, roles from Active Directory groups)
    /// or "Development" (local only, fixed developer identity).
    /// </summary>
    public string Mode { get; set; } = "Jwt";

    public string? Authority { get; set; }

    public string? Audience { get; set; }

    /// <summary>Claim carrying role names in the access token.</summary>
    public string RoleClaimType { get; set; } = "roles";

    public bool RequireHttpsMetadata { get; set; } = true;

    public string[] DevelopmentRoles { get; set; } = [BekpRoles.DashboardViewer, BekpRoles.Integration];

    /// <summary>Windows mode: AD groups (DOMAIN\Group) granted the dashboard viewer role.</summary>
    public string[] WindowsViewerGroups { get; set; } = [];

    /// <summary>Windows mode: AD groups or service accounts' groups granted the integration role (HIS/LIS/blood bank).</summary>
    public string[] WindowsIntegrationGroups { get; set; } = [];

    /// <summary>Windows mode: AD groups granted the administrator role.</summary>
    public string[] WindowsAdminGroups { get; set; } = [];
}

internal static class AuthenticationSetup
{
    public static IServiceCollection AddBekpSecurity(this IServiceCollection services, IConfiguration configuration, IHostEnvironment environment)
    {
        var settings = configuration.GetSection(BekpAuthenticationOptions.SectionName).Get<BekpAuthenticationOptions>() ?? new BekpAuthenticationOptions();

        if (string.Equals(settings.Mode, "Development", StringComparison.OrdinalIgnoreCase))
        {
            // Secure default: the developer identity can never be enabled outside the Development environment.
            if (!environment.IsDevelopment())
            {
                throw new InvalidOperationException("Authentication:Mode=Development is only allowed in the Development environment.");
            }

            services.Configure<BekpAuthenticationOptions>(configuration.GetSection(BekpAuthenticationOptions.SectionName));
            services.AddAuthentication(DevelopmentAuthenticationHandler.SchemeName)
                .AddScheme<AuthenticationSchemeOptions, DevelopmentAuthenticationHandler>(DevelopmentAuthenticationHandler.SchemeName, null);
        }
        else if (string.Equals(settings.Mode, "Windows", StringComparison.OrdinalIgnoreCase))
        {
            if (settings.WindowsViewerGroups.Length == 0 && settings.WindowsAdminGroups.Length == 0)
            {
                throw new InvalidOperationException("Authentication:Mode=Windows requires Authentication:WindowsViewerGroups or WindowsAdminGroups.");
            }

            // IIS performs Windows Authentication (Kerberos/NTLM); ASP.NET Core maps AD groups to BEKP roles.
            services.Configure<BekpAuthenticationOptions>(configuration.GetSection(BekpAuthenticationOptions.SectionName));
            services.AddAuthentication(Microsoft.AspNetCore.Server.IISIntegration.IISDefaults.AuthenticationScheme);
            services.AddTransient<Microsoft.AspNetCore.Authentication.IClaimsTransformation, WindowsGroupRoleTransformation>();
        }
        else
        {
            if (string.IsNullOrWhiteSpace(settings.Authority) || string.IsNullOrWhiteSpace(settings.Audience))
            {
                throw new InvalidOperationException("Authentication:Authority and Authentication:Audience must be configured for JWT authentication.");
            }

            services.AddAuthentication(JwtBearerDefaults.AuthenticationScheme)
                .AddJwtBearer(options =>
                {
                    options.Authority = settings.Authority;
                    options.Audience = settings.Audience;
                    options.RequireHttpsMetadata = settings.RequireHttpsMetadata;
                    options.MapInboundClaims = false;
                    options.TokenValidationParameters.RoleClaimType = settings.RoleClaimType;
                    options.TokenValidationParameters.NameClaimType = "sub";
                    options.Events = new JwtBearerEvents
                    {
                        // Browsers cannot send headers on WebSocket upgrades; SignalR passes the token in the query string.
                        OnMessageReceived = context =>
                        {
                            var token = context.Request.Query["access_token"];
                            if (!string.IsNullOrEmpty(token) && context.HttpContext.Request.Path.StartsWithSegments("/hubs", StringComparison.OrdinalIgnoreCase))
                            {
                                context.Token = token;
                            }

                            return Task.CompletedTask;
                        },
                    };
                });
        }

        services.AddAuthorizationBuilder()
            .SetFallbackPolicy(new AuthorizationPolicyBuilder().RequireAuthenticatedUser().Build())
            .AddPolicy(BekpPolicies.DashboardRead, p => p.RequireRole(BekpRoles.DashboardViewer, BekpRoles.Administrator))
            .AddPolicy(BekpPolicies.InpatientWrite, p => p.RequireRole(BekpRoles.Integration, BekpRoles.Administrator));

        return services;
    }
}
