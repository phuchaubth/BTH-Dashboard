# Cài đặt BEKP trên IIS (chung máy chủ với app Giấy đồng thuận)

BEKP chạy trên **cùng máy chủ IIS và cùng SQL Server** với app Giấy đồng thuận, nhưng là một ứng dụng riêng: site IIS, Application Pool, thư mục, database và repo/nhánh mã nguồn đều tách biệt. Toàn bộ thao tác trên IIS đã gói trong `scripts/iis/Install-BekpSite.ps1`.

| Thành phần | Giấy đồng thuận | BEKP |
|---|---|---|
| Site / Application Pool | giữ nguyên | `BEKP` / `BEKP` (No Managed Code) |
| Thư mục | giữ nguyên | `D:\Sites\BEKP` |
| Database | giữ nguyên | `BEKP` (schema `bekp`) |
| Đăng nhập | — | Windows (nhóm AD) hoặc JWT/OIDC |

## 1. Lấy gói

Có hai cách:
- **Tải từ CI:** GitHub → Actions → CI → artifact `bekp-iis`.
- **Tự build:** `./scripts/publish-iis.ps1 -Output C:\Setup\bekp-iis`, rồi nén thư mục thành `bekp-iis.zip`.

Trong gói có thư mục `_setup` chứa các file cài đặt: `Install-BekpSite.ps1`, `Restore-BekpBackup.ps1`, `create-database.sql`, `master-data-departments.sql` và các migration.

## 2. Máy chủ (một lần)

Cài ASP.NET Core 10.0 Hosting Bundle và bật tính năng WebSocket (`Install-WindowsFeature Web-WebSockets`). Sau đó chạy `net stop was /y` rồi `net start w3svc`.

Bước này **làm gián đoạn app Giấy đồng thuận khoảng 1–5 phút**, nên làm ngoài giờ cao điểm.

## 3. Database (DBA)

1. Chạy `create-database.sql` (thay `<LOGIN>` = `IIS APPPOOL\BEKP` khi SQL Server cùng máy, hoặc tài khoản dịch vụ domain/gMSA khi khác máy).
2. Trên database `BEKP`, chạy migration `001_initial_inpatient_operations.sql`.
3. Sửa bảng `@Khoa` trong `master-data-departments.sql` cho đúng danh mục khoa/giường, rồi chạy.
4. Thêm database `BEKP` vào kế hoạch sao lưu.

## 4. Cài site (PowerShell, chạy bằng quyền Administrator)

```powershell
Set-ExecutionPolicy -Scope Process Bypass -Force
cd C:\Setup\_setup
.\Install-BekpSite.ps1 -PackagePath C:\Setup\bekp-iis.zip -PhysicalPath D:\Sites\BEKP `
  -HostName bekp.benhvien.local -Port 443 -CertificateThumbprint '<thumbprint>' `
  -ConnectionString 'Server=SQLSRV01;Database=BEKP;Integrated Security=true;Encrypt=true' `
  -AuthMode Windows -ViewerGroups 'BV\BEKP-Viewers' -IntegrationGroups 'BV\BEKP-Integration' -AdminGroups 'BV\BEKP-Admins'
```

- **Không có host name riêng:** dùng `-HostName '' -Port 8443`. Không sửa binding của app Giấy đồng thuận.
- **SQL Server ở máy khác:** thêm `-AppPoolAccount 'BV\svc-bekp$'`.
- **Dùng SSO/OIDC thay cho Windows:** `-AuthMode Jwt -JwtAuthority <url> -JwtAudience bekp-api`.
- **Site demo:** cài site riêng trỏ vào database `BEKP_DEMO` và thêm `-DemoData`. **Không bao giờ** dùng `-DemoData` trên database `BEKP` thật.

Cấu hình được ghi vào `applicationHost.config`, không nằm trong gói. Vì vậy cập nhật phiên bản không ghi đè cấu hình, và không có bí mật nào nằm trong repo.

## 5. Kiểm tra

- `/health` trả về `Healthy`.
- Trang `/` hiện **Trực tuyến**, đủ danh sách khoa.
- Tài khoản không thuộc nhóm nào gọi API bị trả 403.
- Tài khoản dịch vụ HIS gọi `PUT /api/inpatient/departments/DEP-0001/beds/201-1/status` bằng `-UseDefaultCredentials` thì dashboard cập nhật ngay.
- App Giấy đồng thuận vẫn hoạt động bình thường.

## 6. Cập nhật / quay lui

- **Cập nhật:** chạy lại `Install-BekpSite.ps1 -PackagePath <gói mới> -PhysicalPath D:\Sites\BEKP -HostName …`. Script tự bật trang bảo trì, sao lưu bản cũ sang `D:\Sites\BEKP.backup-<ngày giờ>`, rồi giữ nguyên cấu hình.
- **Quay lui:** chạy `Restore-BekpBackup.ps1`. Nếu bản lỗi đã chạy migration database thì DBA khôi phục database tương ứng.

## Xử lý sự cố nhanh

| Lỗi | Xử lý |
|---|---|
| 500.19 | Cài lại hoặc chọn Repair Hosting Bundle, rồi `net stop was /y` và `net start w3svc` |
| 500.30 / 500.31 | Xem Event Viewer → Application (*IIS AspNetCore Module V2*): thường do thiếu cấu hình hoặc sai chuỗi kết nối |
| Luôn hiện "Mất kết nối" | Bật WebSocket; cho phép header `Upgrade` tới `/hubs/` |
| Trình duyệt hỏi mật khẩu liên tục | Thêm host BEKP vào vùng Local intranet bằng GPO |
| API trả 403 | Thêm người dùng vào nhóm AD, rồi đăng nhập lại Windows |
