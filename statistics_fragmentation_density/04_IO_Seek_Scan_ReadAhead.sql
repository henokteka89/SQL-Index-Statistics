/*******************************************************************************
  INDEX INTERNALS LAB  -  FILE 04 : I/O - LOGICAL READS, PHYSICAL READS,
                                    READ-AHEAD, SEEKS vs SCANS, COLD vs WARM
  -----------------------------------------------------------------------------
  Goal: read SET STATISTICS IO like a pro, and MEASURE how page density and
        fragmentation affect reads - in memory (warm) and from disk (cold).

  !! This lab uses CHECKPOINT + DBCC DROPCLEANBUFFERS, which empties the data
  !! cache for the WHOLE INSTANCE. Test/dev only. Needs sysadmin.
*******************************************************************************/
USE IndexLab;
GO

/*=============================================================================
  4.1  INDEX DEPTH = reads for a single-row seek
=============================================================================*/
SELECT TableName  = OBJECT_NAME(i.object_id),
       IndexName  = i.name,
       i.type_desc,
       IndexDepth = INDEXPROPERTY(i.object_id, i.name, 'IndexDepth')
FROM sys.indexes AS i
WHERE i.object_id IN (OBJECT_ID('dbo.Orders'), OBJECT_ID('dbo.Frag_Seq'), OBJECT_ID('dbo.Frag_Guid'))
  AND i.index_id > 0
ORDER BY TableName, i.index_id;
GO

/*=============================================================================
  4.2  READING STATISTICS IO: SEEKS AND SCANS THAT SURPRISE PEOPLE
  -----------------------------------------------------------------------------
  Run one query at a time. Look at the operator name in the plan AND the
  logical reads. The operator name alone does not tell you the cost.
=============================================================================*/
SET STATISTICS IO ON;
GO

-- (a) Single-row seek on the clustered primary key.
-- EXPECT: Clustered Index Seek, Scan count 0, logical reads 3 (= IndexDepth).
-- Scan count is 0 because SQL Server knows a unique key can match at most
-- one row, so it doesn't need to "start a scan" along the leaf.
SELECT * FROM dbo.Orders WHERE OrderID = 123456;
GO

-- (b) Unique NC seek + key lookup.
-- EXPECT: Index Seek (UX_Orders_Email) + Key Lookup. Logical reads ~5-6
-- = depth of the Email index + depth of the clustered index.
-- STATISTICS IO adds them together on one line because both are on 'Orders'.
SELECT * FROM dbo.Orders WHERE Email = 'user123456@example.com';
GO

-- (c) Multiple seeks: Scan count > 1.
-- EXPECT: Scan count 5 (one seek per IN value), plus key lookups.
SELECT * FROM dbo.Orders WHERE CustomerID IN (1, 2, 3, 4, 5);
GO

-- (d) A "SEEK" that reads the whole table.
-- EXPECT: Clustered Index Seek ... but logical reads ~13,600 (everything).
-- The seek just finds the starting point (OrderID > 0) and then range-scans
-- the entire leaf. "It's a seek, so it's fine" is a myth - check the reads.
SELECT SUM(Amount) FROM dbo.Orders WHERE OrderID > 0;
GO

-- (e) A small range seek.
-- EXPECT: Clustered Index Seek, logical reads ~3 + ~5 (101 rows / 22 per page).
SELECT SUM(Amount) FROM dbo.Orders WHERE OrderID BETWEEN 1000 AND 1100;
GO

-- (f) A "SCAN" that reads almost nothing.
-- EXPECT: Clustered Index Scan, logical reads a handful. TOP stops the scan
-- as soon as it has 10 rows. "Scans are always bad" is also a myth.
SELECT TOP (10) * FROM dbo.Orders;
GO

-- (g) Key lookups re-read the same upper-level pages over and over.
-- EXPECT: ~3 logical reads PER ROW for the lookups. The root and level-1
-- pages are counted again every time even though they're in memory.
SELECT * FROM dbo.Orders WHERE CustomerID BETWEEN 1 AND 50;   -- 750 rows
GO

SET STATISTICS IO OFF;
GO

/*=============================================================================
  4.3  HELPER: dbo.usp_ScanTest - full clustered scan, cold or warm,
       with real disk I/O measured from sys.dm_io_virtual_file_stats
  -----------------------------------------------------------------------------
  STATISTICS IO tells you how many PAGES came from disk. It does not tell you
  how many I/O REQUESTS that took. sys.dm_io_virtual_file_stats does:

     ReadIOs     = number of read requests sent to the data file
     MBRead      = bytes read
     AvgKBPerIO  = MBRead / ReadIOs   <-- the fragmentation tell-tale
                   Large (e.g. 256-512 KB) = read-ahead got long contiguous
                   runs. Small (8-64 KB) = pages were scattered.

  Notes:
   - MAXDOP 1 keeps the test consistent (parallel scans read differently).
   - WITH (INDEX(1)) forces a scan of the clustered index.
   - File stats count ALL reads on the file, so keep the test box quiet.
=============================================================================*/
CREATE OR ALTER PROCEDURE dbo.usp_ScanTest
    @TableName sysname,
    @ColdCache bit = 1
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @obj int = OBJECT_ID(@TableName);
    IF @obj IS NULL BEGIN RAISERROR('Table %s not found.', 16, 1, @TableName); RETURN; END;

    DECLARE @qualified nvarchar(300) = QUOTENAME(OBJECT_SCHEMA_NAME(@obj)) + N'.' + QUOTENAME(OBJECT_NAME(@obj));
    DECLARE @sql nvarchar(max) =
        N'SELECT @c = COUNT_BIG(*) FROM ' + @qualified + N' WITH (INDEX(1)) OPTION (MAXDOP 1);';
    DECLARE @rows bigint, @r0 bigint, @b0 bigint, @s0 bigint, @t0 datetime2(7);

    IF @ColdCache = 1
    BEGIN
        CHECKPOINT;                               -- write dirty pages so they can be dropped
        DBCC DROPCLEANBUFFERS WITH NO_INFOMSGS;   -- empty the data cache (TEST ONLY)
    END
    ELSE
        EXEC sp_executesql @sql, N'@c bigint OUTPUT', @c = @rows OUTPUT;   -- warm it up first

    SELECT @r0 = num_of_reads, @b0 = num_of_bytes_read, @s0 = io_stall_read_ms
    FROM sys.dm_io_virtual_file_stats(DB_ID(), 1);
    SET @t0 = SYSDATETIME();

    PRINT '---- ' + @TableName + CASE WHEN @ColdCache = 1 THEN ' (COLD cache)' ELSE ' (WARM cache)' END;
    SET STATISTICS IO ON;
    EXEC sp_executesql @sql, N'@c bigint OUTPUT', @c = @rows OUTPUT;
    SET STATISTICS IO OFF;

    SELECT TableName   = @TableName,
           Cache       = CASE WHEN @ColdCache = 1 THEN 'COLD' ELSE 'WARM' END,
           RowsCounted = @rows,
           ElapsedMs   = DATEDIFF(MILLISECOND, @t0, SYSDATETIME()),
           ReadIOs     = f.num_of_reads - @r0,
           MBRead      = CAST((f.num_of_bytes_read - @b0) / 1048576.0 AS decimal(9,1)),
           PagesFromDisk = (f.num_of_bytes_read - @b0) / 8192,
           AvgKBPerIO  = CAST((f.num_of_bytes_read - @b0) / 1024.0 / NULLIF(f.num_of_reads - @r0, 0) AS decimal(9,1)),
           ReadStallMs = f.io_stall_read_ms - @s0
    FROM sys.dm_io_virtual_file_stats(DB_ID(), 1) AS f;
END;
GO

/*=============================================================================
  4.4  COLD vs WARM on the same table
  -----------------------------------------------------------------------------
  Messages tab, COLD run, EXPECT something like:
     logical reads ~13,600, physical reads small (a few), read-ahead ~13,600
     -> almost every page was PRE-FETCHED by read-ahead, not waited for one
        by one. Read-ahead looks at the level above the leaf to see which
        pages are coming next and issues big reads ahead of the scan.
  WARM run, EXPECT:
     logical reads ~13,600 (same!), physical 0, read-ahead 0, ReadIOs 0.
  LESSON: logical reads are stable and comparable; physical/read-ahead
  depend on what happened to be cached. Tune with logical reads; use
  cold tests only to study disk behaviour.
=============================================================================*/
EXEC dbo.usp_ScanTest 'dbo.Orders', 1;   -- cold
EXEC dbo.usp_ScanTest 'dbo.Orders', 0;   -- warm
GO

/*=============================================================================
  4.5  THE FOUR QUADRANTS FROM LAB 03 - COLD
  -----------------------------------------------------------------------------
  EXPECT the PATTERN (absolute numbers depend on your storage):
    Table            logical reads   ReadIOs     AvgKBPerIO
    Frag_Seq          ~8,400          few        large   <- ideal
    Frag_Shrunk       ~8,400          MANY       small   <- same pages, more I/Os
    Frag_LowDensity  ~16,800          ~2x Seq    large   <- 2x pages, still efficient
    Frag_Guid        ~11,500          MANY       small   <- more pages AND small I/Os

  Read it like this:
   - Logical reads follow PAGE COUNT, which follows PAGE DENSITY.
     Fragmentation does NOT change logical reads (Seq vs Shrunk are equal).
   - ReadIOs / AvgKBPerIO follow FRAGMENTATION. Read-ahead can only merge
     pages that are physically next to each other into one big I/O.
   - On a fast SSD the elapsed-time gap is smaller than on spinning disks,
     but the I/O count difference is still there.
=============================================================================*/
EXEC dbo.usp_ScanTest 'dbo.Frag_Seq',        1;
EXEC dbo.usp_ScanTest 'dbo.Frag_Shrunk',     1;
EXEC dbo.usp_ScanTest 'dbo.Frag_LowDensity', 1;
EXEC dbo.usp_ScanTest 'dbo.Frag_Guid',       1;
GO

/*=============================================================================
  4.6  THE FOUR QUADRANTS - WARM
  -----------------------------------------------------------------------------
  EXPECT: ReadIOs 0 for all. Logical reads identical to the cold runs.
  Frag_Seq and Frag_Shrunk now perform the same: once in memory,
  fragmentation is irrelevant. Frag_LowDensity is STILL 2x the work and
  uses 2x the buffer pool memory. Page density hurts even in memory.
=============================================================================*/
EXEC dbo.usp_ScanTest 'dbo.Frag_Seq',        0;
EXEC dbo.usp_ScanTest 'dbo.Frag_Shrunk',     0;
EXEC dbo.usp_ScanTest 'dbo.Frag_LowDensity', 0;
EXEC dbo.usp_ScanTest 'dbo.Frag_Guid',       0;
GO

-- How much buffer pool memory each table is using right now (all four are warm)
SELECT TableName  = OBJECT_NAME(p.object_id),
       PagesInRAM = COUNT(*),
       MBInRAM    = CAST(COUNT(*) * 8 / 1024.0 AS decimal(9,1))
FROM sys.dm_os_buffer_descriptors AS bd
JOIN sys.allocation_units AS au ON au.allocation_unit_id = bd.allocation_unit_id
JOIN sys.partitions       AS p  ON p.hobt_id = au.container_id AND au.type IN (1, 3)
WHERE bd.database_id = DB_ID()
  AND p.object_id IN (OBJECT_ID('dbo.Frag_Seq'), OBJECT_ID('dbo.Frag_Shrunk'),
                      OBJECT_ID('dbo.Frag_LowDensity'), OBJECT_ID('dbo.Frag_Guid'))
GROUP BY p.object_id
ORDER BY PagesInRAM DESC;
GO

/*=============================================================================
  4.7  SEEKS DON'T CARE ABOUT FRAGMENTATION (much)
  -----------------------------------------------------------------------------
  A single-row seek reads one page per level, whether the leaf pages are in
  order or scattered. Cold, both tables need ~3 page reads.
  EXPECT: Frag_Seq and Frag_Shrunk -> logical reads 3, physical reads ~3,
          nearly identical. Fragmentation is a SCAN problem, not a seek problem.
=============================================================================*/
CHECKPOINT; DBCC DROPCLEANBUFFERS WITH NO_INFOMSGS;
SET STATISTICS IO ON;
SELECT * FROM dbo.Frag_Seq    WHERE ID = 123456;
SELECT * FROM dbo.Frag_Shrunk WHERE ID = 123456;
SET STATISTICS IO OFF;
GO

/* Range scans DO care. 20,000 rows (~840 pages), cold.
   EXPECT: same logical reads; compare the read-ahead and the elapsed times.
   On Frag_Shrunk the pages of this range are scattered backwards, so
   read-ahead must issue many small reads instead of a few big ones.        */
CHECKPOINT; DBCC DROPCLEANBUFFERS WITH NO_INFOMSGS;
SET STATISTICS IO, TIME ON;
SELECT SUM(Payload) FROM dbo.Frag_Seq    WHERE ID BETWEEN 50000 AND 70000 OPTION (MAXDOP 1);
CHECKPOINT; DBCC DROPCLEANBUFFERS WITH NO_INFOMSGS;
SELECT SUM(Payload) FROM dbo.Frag_Shrunk WHERE ID BETWEEN 50000 AND 70000 OPTION (MAXDOP 1);
SET STATISTICS IO, TIME OFF;
GO

/*=============================================================================
  4.8  HOW IS EACH INDEX ACTUALLY USED? sys.dm_db_index_usage_stats
  -----------------------------------------------------------------------------
  user_seeks / user_scans / user_lookups since the last restart.
  On production: indexes with lots of SCANS on big tables are where page
  density and fragmentation matter. Indexes used only for SEEKS rarely need
  defragmenting. Indexes with 0 reads and many updates may not be needed.
=============================================================================*/
SELECT TableName = OBJECT_NAME(us.object_id),
       IndexName = i.name,
       us.user_seeks, us.user_scans, us.user_lookups, us.user_updates,
       us.last_user_seek, us.last_user_scan
FROM sys.dm_db_index_usage_stats AS us
JOIN sys.indexes AS i ON i.object_id = us.object_id AND i.index_id = us.index_id
WHERE us.database_id = DB_ID()
ORDER BY TableName, i.index_id;
GO

/*  TAKEAWAYS FROM LAB 04
    - Logical reads = pages touched in memory. Your main, repeatable metric.
    - Physical + read-ahead reads = pages that came from disk. Read-ahead is
      good: big, early, overlapped reads.
    - Page density changes LOGICAL reads (and memory used). Always.
    - Fragmentation changes how many DISK I/Os a scan needs. Only matters
      when pages aren't cached, and mostly for large scans.
    - Seeks of a few rows barely notice either one.
    - Operator names lie: a "seek" can read the whole table, a "scan" can
      read 1 page. Trust the reads.                                         */
