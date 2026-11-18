#Requires -RunAsAdministrator
<#
.SYNOPSIS
  Cài đặt hoặc cập nhật BEKP trên IIS, chạy song song với các ứng dụng hiện có (ví dụ: app Giấy đồng thuận).
  Tạo/giữ nguyên Application Pool và site riêng, chép gói (sao lưu bản cũ), cấp quyền thư mục,
  cấu hình biến môi trường trong applicationHost.config (không ghi vào web.config), kiểm tra /health.
  Chạy lại script để cập nhật phiên bản mới; các tham số cấu hình bỏ trống sẽ được giữ nguyên.

.EXAMPLE
  .\Install-BekpSite.ps1 -PackagePath C:\Setup\bekp-iis.zip -HostName bekp.benhvien.local -Port 443 `
      -CertificateThumbprint 'AB12...' -ConnectionString 'Server=SQLSRV01;Database=BEKP;Integrated Security=true;Encrypt=true' `
      -AuthMode Windows -ViewerGroups 'BV\BEKP-Viewers' -IntegrationGroups 'BV\BEKP-Integration'
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)] [string]$PackagePath,
    [string]$SiteName = 'BEKP',
    [string]$AppPoolName = 'BEKP',
    [string]$PhysicalPath = 'D:\Sites\BEKP',
    [string]$HostName = '',
    [int]$Port = 443,
    [string]$CertificateThumbprint = '',
    [string]$ConnectionString = '',
    # Đăng nhập: 'Windows' (tài khoản domain, phân quyền theo nhóm AD) hoặc 'Jwt' (máy chủ SSO/OIDC).
    [ValidateSet('', 'Windows', 'Jwt')] [string]$AuthMode = '',   # để trống khi cập nhật = giữ nguyên; lần đầu mặc định Windows
    [string[]]$ViewerGroups = @(),       # ví dụ 'BV\BEKP-Viewers'
    [string[]]$IntegrationGroups = @(),  # nhóm chứa tài khoản dịch vụ của HIS/LIS/ngân hàng máu
    [string[]]$AdminGroups = @(),
    [string]$JwtAuthority = '',
    [string]$JwtAudience = '',
    # Site demo: dữ liệu mô phỏng + bộ mô phỏng sự kiện. CHỈ dùng với database demo riêng (ví dụ BEKP_DEMO), không dùng với BEKP thật.
    [switch]$DemoData,
    # Tài khoản chạy Application Pool khi SQL Server ở máy khác, ví dụ 'BV\svc-bekp$' (gMSA). Để trống = ApplicationPoolIdentity.
    [string]$AppPoolAccount = ''
)

$ErrorActionPreference = 'Stop'
Import-Module WebAdministration
$appcmd = Join-Path $env:windir 'system32\inetsrv\appcmd.exe'

function Write-Step([string]$text) { Write-Host "`n== $text" -ForegroundColor Cyan }

# ---------------------------------------------------------------- 1. Kiểm tra điều kiện
Write-Step 'Kiểm tra máy chủ'
$ancm = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\IIS Extensions\IIS AspNetCore Module V2' -ErrorAction SilentlyContinue
if (-not $ancm) { throw 'Chưa cài ASP.NET Core Module V2. Cài "ASP.NET Core 10.0 Hosting Bundle" rồi chạy lại (xem Bước 2).' }
$runtimes = (& dotnet --list-runtimes) -join "`n"
if ($runtimes -notmatch 'Microsoft\.AspNetCore\.App 10\.') { throw 'Chưa có runtime Microsoft.AspNetCore.App 10.x. Cài Hosting Bundle .NET 10.' }
$ws = Get-WindowsFeature -Name Web-WebSockets -ErrorAction SilentlyContinue
if ($ws -and -not $ws.Installed) {
    Write-Host 'Bật tính năng WebSocket Protocol...'
    Install-WindowsFeature -Name Web-WebSockets | Out-Null
}
Write-Host 'OK: ASP.NET Core Module V2, runtime .NET 10, WebSocket Protocol.'

# ---------------------------------------------------------------- 2. Application Pool riêng
Write-Step "Application Pool '$AppPoolName'"
$poolPath = "IIS:\AppPools\$AppPoolName"
if (-not (Test-Path $poolPath)) { New-WebAppPool -Name $AppPoolName | Out-Null; Write-Host 'Đã tạo mới.' } else { Write-Host 'Đã có, giữ nguyên.' }
Set-ItemProperty $poolPath -Name managedRuntimeVersion -Value ''          # No Managed Code
Set-ItemProperty $poolPath -Name managedPipelineMode -Value 'Integrated'
Set-ItemProperty $poolPath -Name startMode -Value 'AlwaysRunning'
Set-ItemProperty $poolPath -Name processModel.idleTimeout -Value ([TimeSpan]::Zero)   # giữ kết nối realtime
Set-ItemProperty $poolPath -Name recycling.periodicRestart.time -Value ([TimeSpan]::Zero)
Set-ItemProperty $poolPath -Name recycling.periodicRestart.schedule -Value @{ value = '03:00:00' }
if ($AppPoolAccount) {
    if ($AppPoolAccount.EndsWith('$')) {
        Set-ItemProperty $poolPath -Name processModel -Value @{ userName = $AppPoolAccount; password = ''; identityType = 3 }
    } else {
        $cred = Get-Credential -UserName $AppPoolAccount -Message 'Mật khẩu tài khoản chạy Application Pool BEKP'
        Set-ItemProperty $poolPath -Name processModel -Value @{ userName = $cred.UserName; password = $cred.GetNetworkCredential().Password; identityType = 3 }
    }
    $identity = $AppPoolAccount
} else {
    Set-ItemProperty $poolPath -Name processModel.identityType -Value 'ApplicationPoolIdentity'
    $identity = "IIS AppPool\$AppPoolName"
}
Write-Host "Danh tính chạy ứng dụng: $identity"

# ---------------------------------------------------------------- 3. Chép gói (sao lưu bản cũ)
Write-Step "Chép gói vào $PhysicalPath"
$source = $PackagePath
if ($PackagePath.EndsWith('.zip', [StringComparison]::OrdinalIgnoreCase)) {
    $source = Join-Path $env:TEMP ("bekp-" + [Guid]::NewGuid().ToString('N'))
    Expand-Archive -Path $PackagePath -DestinationPath $source -Force
}
if (-not (Test-Path (Join-Path $source 'BEKP.Api.dll'))) { throw "Không thấy BEKP.Api.dll trong $PackagePath" }

$siteExists = Test-Path "IIS:\Sites\$SiteName"
New-Item -ItemType Directory -Force -Path $PhysicalPath | Out-Null
if ($siteExists -and (Test-Path (Join-Path $PhysicalPath 'BEKP.Api.dll'))) {
    $backup = "$PhysicalPath.backup-$(Get-Date -Format yyyyMMdd-HHmm)"
    Write-Host "Sao lưu bản đang chạy sang $backup"
    robocopy $PhysicalPath $backup /E /XD logs /NFL /NDL /NJH /NJS | Out-Null
    Copy-Item (Join-Path $source 'app_offline.htm') $PhysicalPath -ErrorAction SilentlyContinue
    if (-not (Test-Path (Join-Path $PhysicalPath 'app_offline.htm'))) {
        Set-Content -Path (Join-Path $PhysicalPath 'app_offline.htm') -Value '<html><body>BEKP đang cập nhật, vui lòng chờ ít phút.</body></html>' -Encoding UTF8
    }
    Start-Sleep -Seconds 5
}
robocopy $source $PhysicalPath /MIR /XD logs _setup /XF app_offline.htm /NFL /NDL /NJH /NJS | Out-Null
if ($LASTEXITCODE -ge 8) { throw "robocopy lỗi (mã $LASTEXITCODE)" }
New-Item -ItemType Directory -Force -Path (Join-Path $PhysicalPath 'logs') | Out-Null

# ---------------------------------------------------------------- 4. Quyền thư mục (chỉ cho tài khoản của BEKP)
Write-Step 'Cấp quyền thư mục'
icacls $PhysicalPath /grant "${identity}:(OI)(CI)RX" /T /Q | Out-Null
icacls (Join-Path $PhysicalPath 'logs') /grant "${identity}:(OI)(CI)M" /T /Q | Out-Null
Write-Host "Đọc: $PhysicalPath · Ghi: logs"

# ---------------------------------------------------------------- 5. Site IIS riêng
Write-Step "Site '$SiteName'"
$https = $Port -eq 443 -or $CertificateThumbprint
if (-not $siteExists) {
    if ($https) {
        New-Website -Name $SiteName -PhysicalPath $PhysicalPath -ApplicationPool $AppPoolName -Port $Port -HostHeader $HostName -Ssl -SslFlags $(if ($HostName) { 1 } else { 0 }) | Out-Null
    } else {
        New-Website -Name $SiteName -PhysicalPath $PhysicalPath -ApplicationPool $AppPoolName -Port $Port -HostHeader $HostName | Out-Null
    }
    Write-Host "Đã tạo site, cổng $Port, host '$HostName'."
} else {
    Set-ItemProperty "IIS:\Sites\$SiteName" -Name physicalPath -Value $PhysicalPath
    Set-ItemProperty "IIS:\Sites\$SiteName" -Name applicationPool -Value $AppPoolName
    Write-Host 'Site đã có: giữ nguyên binding.'
}
if ($CertificateThumbprint) {
    $binding = Get-WebBinding -Name $SiteName -Protocol https | Select-Object -First 1
    if ($binding) { $binding.AddSslCertificate($CertificateThumbprint.Replace(' ', ''), 'My'); Write-Host 'Đã gắn chứng chỉ HTTPS.' }
}

# ---------------------------------------------------------------- 6. Cấu hình (applicationHost.config, không nằm trong gói)
Write-Step 'Cấu hình biến môi trường'
function Set-SiteVariable([string]$name, [string]$value) {
    if ([string]::IsNullOrWhiteSpace($value)) { return }
    $escaped = $value.Replace("'", "''")
    & $appcmd set config $SiteName -section:system.webServer/aspNetCore /-"environmentVariables.[name='$name']" /commit:apphost 2>$null | Out-Null
    & $appcmd set config $SiteName -section:system.webServer/aspNetCore /+"environmentVariables.[name='$name',value='$escaped']" /commit:apphost | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "Không đặt được $name" }
    Write-Host "Đã đặt $name"
}
if (-not $AuthMode -and -not $siteExists) { $AuthMode = 'Windows' }
Set-SiteVariable 'ConnectionStrings__Bekp' $ConnectionString
Set-SiteVariable 'Authentication__Mode' $AuthMode
if ($DemoData) {
    Write-Warning 'Chế độ DEMO: sinh dữ liệu mô phỏng. Chỉ dùng với database demo riêng.'
    Set-SiteVariable 'ASPNETCORE_ENVIRONMENT' 'Staging'
    Set-SiteVariable 'Database__SeedSyntheticData' 'true'
    Set-SiteVariable 'Simulation__Enabled' 'true'
}
if ($AuthMode -eq 'Windows') {
    if ($ViewerGroups.Count -eq 0 -and $AdminGroups.Count -eq 0 -and -not $siteExists) {
        throw 'Chế độ Windows cần ít nhất -ViewerGroups hoặc -AdminGroups.'
    }
    for ($i = 0; $i -lt $ViewerGroups.Count; $i++) { Set-SiteVariable "Authentication__WindowsViewerGroups__$i" $ViewerGroups[$i] }
    for ($i = 0; $i -lt $IntegrationGroups.Count; $i++) { Set-SiteVariable "Authentication__WindowsIntegrationGroups__$i" $IntegrationGroups[$i] }
    for ($i = 0; $i -lt $AdminGroups.Count; $i++) { Set-SiteVariable "Authentication__WindowsAdminGroups__$i" $AdminGroups[$i] }
    # IIS xác thực Windows (Kerberos/NTLM); vẫn bật Anonymous để /health và file giao diện tải được, API tự yêu cầu đăng nhập.
    & $appcmd set config $SiteName -section:system.webServer/security/authentication/windowsAuthentication /enabled:"True" /commit:apphost | Out-Null
    & $appcmd set config $SiteName -section:system.webServer/security/authentication/anonymousAuthentication /enabled:"True" /commit:apphost | Out-Null
    Write-Host 'Đã bật Windows Authentication cho site.'
} elseif ($AuthMode -eq 'Jwt') {
    Set-SiteVariable 'Authentication__Authority' $JwtAuthority
    Set-SiteVariable 'Authentication__Audience' $JwtAudience
}

# ---------------------------------------------------------------- 7. Khởi động và kiểm tra
Write-Step 'Khởi động'
Remove-Item (Join-Path $PhysicalPath 'app_offline.htm') -ErrorAction SilentlyContinue
if ((Get-WebAppPoolState -Name $AppPoolName).Value -ne 'Started') { Start-WebAppPool -Name $AppPoolName } else { Restart-WebAppPool -Name $AppPoolName }
if ((Get-WebsiteState -Name $SiteName).Value -ne 'Started') { Start-Website -Name $SiteName }

$hostForTest = if ($HostName) { $HostName } else { 'localhost' }
$scheme = if ($https) { 'https' } else { 'http' }
$url = "${scheme}://${hostForTest}:$Port/health"
Start-Sleep -Seconds 3
try {
    $response = Invoke-WebRequest -Uri $url -UseBasicParsing -TimeoutSec 30
    Write-Host "Kiểm tra $url -> $($response.StatusCode) $($response.Content)" -ForegroundColor Green
} catch {
    Write-Warning "Chưa gọi được $url ($($_.Exception.Message)). Xem mục Xử lý sự cố trong hướng dẫn."
}
Write-Host "`nHoàn tất. Mở ${scheme}://${hostForTest}:$Port/ để kiểm tra giao diện." -ForegroundColor Green
