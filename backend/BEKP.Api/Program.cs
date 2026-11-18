using System.Text.Json;
using System.Text.Json.Serialization;
using BEKP.Api.Middleware;
using BEKP.Api.Security;
using BEKP.Application;
using BEKP.Application.Common;
using BEKP.Application.TimeStandards;
using BEKP.Infrastructure;
using BEKP.Infrastructure.Realtime;
using BEKP.Infrastructure.Simulation;
using BEKP.Persistence;

var builder = WebApplication.CreateBuilder(args);
var configuration = builder.Configuration;

builder.Services.Configure<HospitalTimeOptions>(configuration.GetSection(HospitalTimeOptions.SectionName));
builder.Services.Configure<TimeStandardsOptions>(configuration.GetSection(TimeStandardsOptions.SectionName));
builder.Services.Configure<DatabaseOptions>(configuration.GetSection(DatabaseOptions.SectionName));
builder.Services.Configure<SimulationOptions>(configuration.GetSection(SimulationOptions.SectionName));

builder.Services
    .AddApplication()
    .AddPersistence(configuration.GetConnectionString(BEKP.Persistence.DependencyInjection.ConnectionStringName))
    .AddInfrastructure()
    .AddBekpSecurity(configuration, builder.Environment);

var enumConverter = new JsonStringEnumConverter(JsonNamingPolicy.CamelCase, allowIntegerValues: false);
builder.Services.AddControllers().AddJsonOptions(o => o.JsonSerializerOptions.Converters.Add(enumConverter));
builder.Services.AddSignalR().AddJsonProtocol(o => o.PayloadSerializerOptions.Converters.Add(enumConverter));
builder.Services.AddProblemDetails();
builder.Services.AddExceptionHandler<ApiExceptionHandler>();
builder.Services.AddHealthChecks();

var allowedOrigins = configuration.GetSection("Cors:AllowedOrigins").Get<string[]>() ?? [];
builder.Services.AddCors(options => options.AddDefaultPolicy(policy =>
{
    if (allowedOrigins.Length > 0)
    {
        policy.WithOrigins(allowedOrigins).AllowAnyHeader().WithMethods("GET", "POST", "PUT").AllowCredentials();
    }
}));

var app = builder.Build();

app.UseExceptionHandler();
app.UseStatusCodePages();
app.UseSecurityHeaders();
if (!app.Environment.IsDevelopment())
{
    app.UseHsts();
}

app.UseCors();
app.UseAuthentication();
app.UseAuthorization();

app.MapControllers();
app.MapHub<DashboardHub>(DashboardHub.Path);
app.MapHealthChecks("/health").AllowAnonymous();

await app.RunAsync().ConfigureAwait(false);

/// <summary>Entry point, exposed for integration tests.</summary>
public partial class Program;
