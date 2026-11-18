/*
  BEKP – khai báo danh mục khoa và giường (dữ liệu nền, không chứa thông tin người bệnh).
  Chạy trên database BEKP SAU script migration. DBA chỉnh bảng @Khoa cho đúng thực tế:
    Code        mã khoa BEKP, dạng DEP-0000 (HIS gửi dữ liệu theo mã này)
    Name        tên khoa hiển thị
    GroupName   MalignantHematology | BenignHematology | PediatricHematology | StemCellTransplant | IntensiveCare
    Sterile     1 = khoa có phòng vô trùng (ghép tế bào gốc)
    Floor       tầng (dùng đánh số phòng: tầng 2 -> phòng 201, 202…)
    Beds        số giường kế hoạch
    BedsPerRoom số giường mỗi phòng
    Prefix      NULL = mã giường theo phòng (201-1); 'VT' / 'HS' = mã giường theo khu (VT-01)
    ZoneLabel   tên khu khi có Prefix (ví dụ N'Khu vô trùng')
  Script an toàn khi chạy lại: khoa đã có (cùng Code) sẽ được bỏ qua.
*/
SET NOCOUNT ON;
SET XACT_ABORT ON;

DECLARE @Khoa TABLE (
    SortOrder int, Code varchar(16), Name nvarchar(120), Description nvarchar(250), GroupName varchar(40),
    Sterile bit, Floor int, Beds int, BedsPerRoom int, Prefix varchar(4) NULL, ZoneLabel nvarchar(30) NULL);

INSERT INTO @Khoa VALUES
 (1, 'DEP-0001', N'Bạch cầu cấp người lớn', N'Lơ-xê-mi cấp, hóa trị tấn công và củng cố', 'MalignantHematology', 0, 2, 48, 6, NULL, NULL),
 (2, 'DEP-0002', N'U lympho – Đa u tủy', N'U lympho, đa u tủy xương, hóa – miễn dịch', 'MalignantHematology', 0, 3, 44, 6, NULL, NULL),
 (3, 'DEP-0003', N'Huyết học Nhi', N'Bệnh máu ác tính và lành tính trẻ em', 'PediatricHematology', 0, 4, 50, 6, NULL, NULL),
 (4, 'DEP-0004', N'Ghép tế bào gốc tạo máu', N'Ghép tự thân và đồng loài, phòng vô trùng HEPA', 'StemCellTransplant', 1, 5, 12, 6, 'VT', N'Khu vô trùng'),
 (5, 'DEP-0005', N'Thalassemia & Bệnh lý hồng cầu', N'Truyền máu định kỳ, thải sắt, thiếu máu tan máu', 'BenignHematology', 0, 6, 40, 6, NULL, NULL),
 (6, 'DEP-0006', N'Hemophilia & Rối loạn đông máu', N'Hemophilia, von Willebrand, rối loạn đông cầm máu', 'BenignHematology', 0, 7, 30, 6, NULL, NULL),
 (7, 'DEP-0007', N'Suy tủy & Bệnh lý tủy lành tính', N'Suy tủy xương, giảm tiểu cầu miễn dịch', 'BenignHematology', 0, 8, 32, 6, NULL, NULL),
 (8, 'DEP-0008', N'Hồi sức tích cực Huyết học', N'Hồi sức người bệnh huyết học nặng', 'IntensiveCare', 0, 1, 16, 4, 'HS', N'Khu hồi sức');

DECLARE @ExtraBeds int = 3;   -- số giường kê thêm dự phòng mỗi khoa (không tính vào công suất)
DECLARE @Now datetime2 = SYSUTCDATETIME();

BEGIN TRAN;

DECLARE @code varchar(16), @floor int, @beds int, @per int, @prefix varchar(4), @zone nvarchar(30), @deptId uniqueidentifier, @i int;
DECLARE k CURSOR LOCAL FAST_FORWARD FOR
    SELECT Code, Floor, Beds, BedsPerRoom, Prefix, ZoneLabel FROM @Khoa WHERE Code NOT IN (SELECT Code FROM bekp.Departments) ORDER BY SortOrder;
OPEN k;
FETCH NEXT FROM k INTO @code, @floor, @beds, @per, @prefix, @zone;
WHILE @@FETCH_STATUS = 0
BEGIN
    SET @deptId = NEWID();
    INSERT INTO bekp.Departments (Id, Code, Name, Description, [Group], IsSterileUnit, SortOrder)
    SELECT @deptId, Code, Name, Description, GroupName, Sterile, SortOrder FROM @Khoa WHERE Code = @code;

    SET @i = 0;
    WHILE @i < @beds
    BEGIN
        INSERT INTO bekp.Beds (Id, DepartmentId, Code, RoomLabel, IsExtra, SortOrder, Status, StatusChangedAtUtc)
        VALUES (
            NEWID(), @deptId,
            CASE WHEN @prefix IS NULL
                 THEN CONCAT(@floor * 100 + @i / @per + 1, '-', @i % @per + 1)
                 ELSE CONCAT(@prefix, '-', RIGHT(CONCAT('0', @i + 1), 2)) END,
            CASE WHEN @prefix IS NULL
                 THEN CONCAT(N'Phòng ', @floor * 100 + @i / @per + 1)
                 ELSE CONCAT(@zone, N' ', NCHAR(65 + @i / @per)) END,
            0, @i, 'Available', @Now);
        SET @i += 1;
    END;

    SET @i = 1;
    WHILE @i <= @ExtraBeds
    BEGIN
        INSERT INTO bekp.Beds (Id, DepartmentId, Code, RoomLabel, IsExtra, SortOrder, Status, StatusChangedAtUtc)
        VALUES (NEWID(), @deptId, CONCAT('KT-', @i), N'Kê thêm', 1, 1000 + @i, 'Available', @Now);
        SET @i += 1;
    END;

    PRINT CONCAT('Đã tạo khoa ', @code, ': ', @beds, ' giường + ', @ExtraBeds, ' giường kê thêm');
    FETCH NEXT FROM k INTO @code, @floor, @beds, @per, @prefix, @zone;
END;
CLOSE k;
DEALLOCATE k;

COMMIT;

SELECT d.Code, d.Name, COUNT(CASE WHEN b.IsExtra = 0 THEN 1 END) AS GiuongKeHoach, COUNT(CASE WHEN b.IsExtra = 1 THEN 1 END) AS GiuongKeThem
FROM bekp.Departments d LEFT JOIN bekp.Beds b ON b.DepartmentId = d.Id
GROUP BY d.Code, d.Name, d.SortOrder ORDER BY d.SortOrder;
