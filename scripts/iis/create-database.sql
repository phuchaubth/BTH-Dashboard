/*
  BEKP – tạo database riêng trên SQL Server dùng chung (chạy bằng tài khoản sysadmin / DBA).
  Thay <LOGIN> bằng:
    - [IIS APPPOOL\BEKP]      nếu SQL Server cài cùng máy với IIS;
    - [BV\svc-bekp$]          (gMSA / tài khoản dịch vụ domain) nếu SQL Server ở máy khác.
  Sau đó chạy database/migrations/001_initial_inpatient_operations.sql trên database BEKP.
*/
IF DB_ID(N'BEKP') IS NULL
    CREATE DATABASE [BEKP];
GO
IF NOT EXISTS (SELECT 1 FROM sys.server_principals WHERE name = N'<LOGIN>')
    CREATE LOGIN [<LOGIN>] FROM WINDOWS WITH DEFAULT_DATABASE = [BEKP];
GO
USE [BEKP];
GO
IF NOT EXISTS (SELECT 1 FROM sys.database_principals WHERE name = N'<LOGIN>')
    CREATE USER [<LOGIN>] FOR LOGIN [<LOGIN>];
ALTER ROLE db_datareader ADD MEMBER [<LOGIN>];
ALTER ROLE db_datawriter ADD MEMBER [<LOGIN>];
GO
