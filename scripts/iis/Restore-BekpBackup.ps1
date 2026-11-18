#Requires -RunAsAdministrator
<#
.SYNOPSIS
  Quay lui BEKP về bản sao lưu gần nhất do Install-BekpSite.ps1 tạo (D:\Sites\BEKP.backup-yyyyMMdd-HHmm).
#>
[CmdletBinding()]
param(
    [string]$SiteName = 'BEKP',
    [string]$AppPoolName = 'BEKP',
    [string]$PhysicalPath = 'D:\Sites\BEKP',
    [string]$BackupPath = ''
)
$ErrorActionPreference = 'Stop'
Import-Module WebAdministration
if (-not $BackupPath) {
    $BackupPath = Get-ChildItem -Path (Split-Path $PhysicalPath) -Directory -Filter "$(Split-Path $PhysicalPath -Leaf).backup-*" |
        Sort-Object Name -Descending | Select-Object -First 1 -ExpandProperty FullName
}
if (-not $BackupPath -or -not (Test-Path (Join-Path $BackupPath 'BEKP.Api.dll'))) { throw 'Không tìm thấy bản sao lưu hợp lệ.' }
Write-Host "Quay lui từ $BackupPath"
Set-Content -Path (Join-Path $PhysicalPath 'app_offline.htm') -Value '<html><body>BEKP đang khôi phục.</body></html>' -Encoding UTF8
Start-Sleep -Seconds 5
robocopy $BackupPath $PhysicalPath /MIR /XD logs /XF app_offline.htm /NFL /NDL /NJH /NJS | Out-Null
if ($LASTEXITCODE -ge 8) { throw "robocopy lỗi (mã $LASTEXITCODE)" }
Remove-Item (Join-Path $PhysicalPath 'app_offline.htm')
Restart-WebAppPool -Name $AppPoolName
Write-Host 'Đã quay lui. Lưu ý: nếu bản mới đã chạy migration database, cần DBA khôi phục database tương ứng.' -ForegroundColor Yellow
