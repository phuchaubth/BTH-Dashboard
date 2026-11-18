# syntax=docker/dockerfile:1
FROM mcr.microsoft.com/dotnet/sdk:10.0 AS build
WORKDIR /src
COPY Directory.Build.props Directory.Packages.props ./
COPY BEKP.Shared/BEKP.Shared.csproj BEKP.Shared/
COPY BEKP.Domain/BEKP.Domain.csproj BEKP.Domain/
COPY BEKP.Application/BEKP.Application.csproj BEKP.Application/
COPY BEKP.Persistence/BEKP.Persistence.csproj BEKP.Persistence/
COPY BEKP.Infrastructure/BEKP.Infrastructure.csproj BEKP.Infrastructure/
COPY BEKP.Api/BEKP.Api.csproj BEKP.Api/
RUN dotnet restore BEKP.Api/BEKP.Api.csproj
COPY . .
RUN dotnet publish BEKP.Api/BEKP.Api.csproj -c Release -o /app --no-restore

FROM mcr.microsoft.com/dotnet/aspnet:10.0
WORKDIR /app
ENV ASPNETCORE_URLS=http://+:8080 \
    DOTNET_RUNNING_IN_CONTAINER=true
COPY --from=build /app .
USER $APP_UID
EXPOSE 8080
ENTRYPOINT ["dotnet", "BEKP.Api.dll"]
