/*******************************************************************************
  INDEX INTERNALS LAB  -  FILE 00 : CONCEPTS + SETUP
  -----------------------------------------------------------------------------
  Target    : SQL Server 2016 or later (Developer Edition is ideal)
  WHERE     : A TEST / DEV INSTANCE ONLY.
              Later labs run DBCC DROPCLEANBUFFERS (empties the whole instance's
              data cache) and DBCC SHRINKFILE. Never run those on production.
  Run order : 00 -> 01 -> 02 -> 03 -> 04 -> 05
  Disk      : ~1 GB free is plenty.
  How to use: Run ONE section at a time (highlight it, press F5).
              In SSMS turn on "Include Actual Execution Plan" (Ctrl+M) and
              read BOTH the Messages tab (I/O numbers) and the Execution Plan tab.
  Note      : Exact numbers on your machine will differ a little from the
              "EXPECT" notes. The pattern is what matters.
*******************************************************************************/

/*=============================================================================
  READ THIS FIRST - THE VOCABULARY (in plain English)
===============================================================================

 1. PAGE
    SQL Server stores ALL table and index data in 8 KB pages (8,192 bytes).
    About 8,060 bytes are usable for rows. The rest is a 96-byte page header
    plus a "slot array" (2 bytes per row that says where each row starts).

    KEY IDEA: SQL Server never reads "a row". It reads the whole PAGE the row
    lives on. So the cost of a query is measured in PAGES touched, not rows.
    Fewer pages = less I/O, less memory, less CPU.

 2. EXTENT
    8 pages that sit next to each other on disk = 1 extent = 64 KB.
    Space is handed to tables in extents.

 3. B-TREE, LEVELS AND INDEX DEPTH
    An index (clustered or nonclustered) is a tree of pages:

          [ root page ]                 <- level 2 (top)
           /    |    \
      [int]  [int]  [int]               <- level 1 (intermediate)
      / | \  / | \  / | \
     [leaf][leaf][leaf] ... [leaf]      <- level 0 (leaf)

    - LEAF level (level 0): in a CLUSTERED index the leaf pages ARE the table
      rows. In a NONCLUSTERED index the leaf pages hold the index key plus a
      pointer back to the row (the clustered key).
    - INDEX DEPTH = number of levels. To find ONE row by key, SQL Server reads
      one page per level. Depth 3 = 3 page reads for a single-row seek.
    - Leaf pages are linked to each other in KEY ORDER (each page knows its
      previous and next page). That chain is what a range scan follows.

 4. HEAP vs CLUSTERED TABLE
    Heap = table with no clustered index; rows are in no particular order.
    Clustered = rows are stored in the leaf of a B-tree, sorted by the key.
    This lab uses clustered tables.

 5. ROWS, PAGE COUNT, ROWS PER PAGE
    rows per page  ~= 8,096 / (average row size + 2)
    page count     ~= row count / rows per page    (when pages are full)
    Wide rows -> fewer rows per page -> more pages -> more reads.

 6. "DENSITY" - WARNING: TWO COMPLETELY DIFFERENT THINGS USE THIS WORD
    ---------------------------------------------------------------------------
    6a. STATISTICS DENSITY  (about the DATA VALUES)
        Density = 1 / (number of distinct values in the column)

        Status column with 5 values      -> density 1/5      = 0.2   (HIGH)
        CustomerID with 20,000 values    -> density 1/20,000 = 0.00005 (LOW)
        Email, all unique (300,000)      -> density 1/300,000 (VERY LOW)

        HIGH density = few distinct values = each value matches MANY rows
                     = "not selective" -> optimizer tends to SCAN.
        LOW density  = many distinct values = each value matches FEW rows
                     = "selective" -> optimizer tends to SEEK.

        It lives in the statistics object (DBCC SHOW_STATISTICS) and the
        optimizer uses it to GUESS how many rows a query returns.
        It has NOTHING to do with how full pages are or with fragmentation.

    6b. PAGE DENSITY  (about PHYSICAL STORAGE)
        = avg_page_space_used_in_percent in sys.dm_db_index_physical_stats
        = how full the pages are, on average.

        HIGH page density (90-100%) = pages are packed = fewest pages.
        LOW page density (say 50%)  = pages half empty = TWICE the pages
                                      for the same rows = twice the reads
                                      and twice the memory for a scan.
        Older articles call low page density "internal fragmentation".

    When someone says "density", ask: statistics density or page density?
    ---------------------------------------------------------------------------

 7. FRAGMENTATION (logical / "external" fragmentation)
    = avg_fragmentation_in_percent in sys.dm_db_index_physical_stats.
    The leaf pages are linked in key order. Ideally page 1 -> page 2 ->
    page 3 sit next to each other in the data file. A page is "out of order"
    when the next page in KEY order is not the next page in the FILE.
    Fragmentation % = out-of-order leaf pages / total leaf pages.

    Related columns:
      fragment_count             = number of runs of physically contiguous pages
      avg_fragment_size_in_pages = average length of those runs
                                   (big = good, 1-2 = badly scattered)

    Why it matters: when SQL Server READS FROM DISK during a scan, it can grab
    long runs of contiguous pages in a few large I/Os. Scattered pages force
    many small I/Os. Once pages are already in memory, fragmentation costs
    almost nothing - memory doesn't care where the page sat in the file.

 8. PAGE SPLIT
    A row must go into a page that is full (an INSERT in the middle of the key
    range, or an UPDATE that makes a row longer). SQL Server allocates a new
    page, moves about half the rows to it, and links it into the chain.
    Result: TWO half-full pages (low page density) and the new page is usually
    somewhere else in the file (fragmentation). Splits also write a lot of log.
    Classic cause: a clustered key of NEWID() GUIDs (random insert positions).
    Adding a row at the END of an ever-increasing key (IDENTITY) is cheap: a
    new page is simply added at the end, no rows move.

 9. FILL FACTOR
    The % of each leaf page to fill when an index is BUILT or REBUILT.
    FILLFACTOR = 100 (or 0, which means 100) -> packed pages.
    FILLFACTOR = 70 -> 30% left empty for future inserts (fewer splits)
    but 30% more pages to read today. It is only applied at build/rebuild;
    normal inserts fill pages all the way.

 10. SEEK vs SCAN vs KEY LOOKUP
    INDEX SEEK : walk the tree from root to leaf to the first matching key,
                 then read just the matching range. Cheap for few rows.
    INDEX SCAN : read every leaf page of the index (unless something like TOP
                 stops it early). Cost = page count.
    KEY LOOKUP : the nonclustered index found the row but does not contain all
                 the columns the query needs, so for EACH row SQL Server does
                 another seek into the clustered index (depth reads each time).
                 1,000 rows x 3 levels = ~3,000 extra page reads.
    TIPPING POINT: the row count where "seek + lookups" costs more than just
                 scanning the whole table. Often only a few % of the table's
                 rows. This is WHY high-density (non-selective) columns get
                 scanned even when an index exists on them.

 11. SET STATISTICS IO ON  - the numbers in the Messages tab
    Table 'Orders'. Scan count 1, logical reads 13650, physical reads 2,
    read-ahead reads 13640, lob logical reads 0 ...

    Scan count        : how many separate seeks/scans of that table/index were
                        started. A unique single-value seek can show 0.
                        IN (1,2,3) often shows 3. Inside a nested loop join
                        it can be in the thousands.
    logical reads     : pages read FROM MEMORY (the buffer pool). Every page
                        the query touched counts, even if it was read from
                        disk first. The same page touched twice counts twice.
                        THIS IS YOUR MAIN TUNING NUMBER - it doesn't change
                        with what's cached, so it's repeatable.
    physical reads    : pages SQL Server had to wait for, read from disk one at
                        a time because they weren't in memory.
    read-ahead reads  : pages SQL Server PRE-FETCHED from disk because it
                        predicted the scan would need them soon. Read-ahead
                        uses large I/Os and overlaps with processing.
                        physical + read-ahead ~= pages that came from disk.
                        Both are 0 when everything is already cached ("warm").
    lob logical reads : pages of large values (varchar(max), etc.).

 12. ESTIMATED vs ACTUAL ROWS
    In the actual plan, hover over an operator. If "Estimated Number of Rows"
    is far from "Actual Number of Rows", the optimizer guessed wrong - often
    because of statistics density (it used an average) or stale statistics.

 13. HOW THE TWO DENSITIES AND FRAGMENTATION RELATE
    - Statistics density decides the PLAN SHAPE (seek vs scan).
    - Page density decides HOW MANY PAGES a scan reads (logical reads).
    - Fragmentation decides HOW EFFICIENTLY those pages come off DISK.
    A query on a selective (low statistics density) column does a small seek
    and barely notices fragmentation. A query on a non-selective (high
    statistics density) column scans, and that is where page density and
    fragmentation actually hurt. Labs 01-04 prove each of these.
=============================================================================*/


/*=============================================================================
  SETUP SECTION 0.1 - Create the lab database
=============================================================================*/
USE master;
GO
IF DB_ID(N'IndexLab') IS NOT NULL
BEGIN
    ALTER DATABASE IndexLab SET SINGLE_USER WITH ROLLBACK IMMEDIATE;
    DROP DATABASE IndexLab;
END
GO
CREATE DATABASE IndexLab;
GO
ALTER DATABASE IndexLab SET RECOVERY SIMPLE;          -- keep the log small
ALTER DATABASE IndexLab SET AUTO_CREATE_STATISTICS ON;
ALTER DATABASE IndexLab SET AUTO_UPDATE_STATISTICS ON;
GO
USE IndexLab;
GO

/*=============================================================================
  SETUP SECTION 0.2 - Numbers function (generates 1..N quickly)
  Cross-joining small sets multiplies rows: 10 x 10 = 100, 100 x 100 = 10,000,
  10,000 x 10,000 = 100,000,000. TOP (@n) stops after @n rows.
=============================================================================*/
CREATE OR ALTER FUNCTION dbo.fn_Numbers (@n bigint)
RETURNS TABLE
AS
RETURN
WITH L0 AS (SELECT c FROM (VALUES (1),(1),(1),(1),(1),(1),(1),(1),(1),(1)) AS v(c)),
     L1 AS (SELECT 1 AS c FROM L0 AS a CROSS JOIN L0 AS b),
     L2 AS (SELECT 1 AS c FROM L1 AS a CROSS JOIN L1 AS b),
     L3 AS (SELECT 1 AS c FROM L2 AS a CROSS JOIN L2 AS b)
SELECT TOP (@n) n = ROW_NUMBER() OVER (ORDER BY (SELECT NULL))
FROM L3;
GO

/*=============================================================================
  SETUP SECTION 0.3 - Main table dbo.Orders (300,000 rows)

  Each column is designed to have a DIFFERENT statistics density:
    OrderID    : unique (identity)          -> density 1/300,000 (very low)
    CustomerID : 20,000 values, 15 rows each -> density 1/20,000  (low)
    Status     : 5 values, 60,000 rows each  -> density 1/5 = 0.2 (high)
    IsActive   : 2 values, SKEWED 99% / 1%   -> density 1/2 = 0.5 (high)
                 (density is an AVERAGE - it hides the skew; see Lab 01)
    Region     : 10 values                   -> density 0.1 (high)
    Email      : unique                      -> density 1/300,000
  Filler CHAR(300) makes rows wide (~355 bytes) so we get ~22 rows per page
  and a realistic number of pages (~13,500) to measure.
=============================================================================*/
DROP TABLE IF EXISTS dbo.Orders;
CREATE TABLE dbo.Orders
(
    OrderID     int IDENTITY(1,1) NOT NULL,
    CustomerID  int           NOT NULL,
    Status      tinyint       NOT NULL,
    IsActive    bit           NOT NULL,
    Region      char(2)       NOT NULL,
    OrderDate   date          NOT NULL,
    Email       varchar(100)  NOT NULL,
    Amount      decimal(10,2) NOT NULL,
    Filler      char(300)     NOT NULL CONSTRAINT DF_Orders_Filler DEFAULT ('x'),
    CONSTRAINT PK_Orders PRIMARY KEY CLUSTERED (OrderID)
);

INSERT dbo.Orders (CustomerID, Status, IsActive, Region, OrderDate, Email, Amount)
SELECT
    CustomerID = (n % 20000) + 1,
    Status     = n % 5,
    IsActive   = CASE WHEN n % 100 = 0 THEN 0 ELSE 1 END,      -- 1% are 0
    Region     = CHOOSE(n % 10 + 1, 'NE','SE','MW','SW','NW','CA','TX','FL','NY','PA'),
    OrderDate  = DATEADD(DAY, -CAST(n % 1095 AS int), CAST('2026-01-01' AS date)),
    Email      = CONCAT('user', n, '@example.com'),
    Amount     = CAST((n % 1000) + 0.99 AS decimal(10,2))
FROM dbo.fn_Numbers(300000)
ORDER BY n;   -- sequential load into the identity key = no fragmentation
GO

/*=============================================================================
  SETUP SECTION 0.4 - Nonclustered indexes, one per "density" type
  Creating an index also creates a statistics object with the SAME NAME,
  built with a FULL SCAN, so the density numbers in Lab 01 are exact.
=============================================================================*/
CREATE INDEX IX_Orders_CustomerID ON dbo.Orders (CustomerID);   -- low density
CREATE INDEX IX_Orders_Status     ON dbo.Orders (Status);       -- high density
CREATE INDEX IX_Orders_IsActive   ON dbo.Orders (IsActive);     -- high density, skewed
CREATE UNIQUE INDEX UX_Orders_Email ON dbo.Orders (Email);      -- unique
GO

/*=============================================================================
  SETUP SECTION 0.5 - Helper procedure: dbo.usp_PageStats
  Wraps sys.dm_db_index_physical_stats so every lab can call:
      EXEC dbo.usp_PageStats 'dbo.Orders';          -- leaf level only
      EXEC dbo.usp_PageStats 'dbo.Orders', 0;       -- every level of the tree

  WHY 'DETAILED' MODE: the DMV has 3 modes.
    LIMITED  - fastest, reads only the level above the leaf. Gives page count
               and fragmentation, but avg_page_space_used_in_percent and
               record_count come back NULL.
    SAMPLED  - reads 1% of leaf pages if the index is large. Good estimate.
    DETAILED - reads every page. Exact. Fine for a lab; on a big production
               database prefer LIMITED or SAMPLED.
=============================================================================*/
CREATE OR ALTER PROCEDURE dbo.usp_PageStats
    @TableName sysname,
    @LeafOnly  bit = 1
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @obj int = OBJECT_ID(@TableName);
    IF @obj IS NULL
    BEGIN
        RAISERROR('Table %s not found in this database.', 16, 1, @TableName);
        RETURN;
    END;

    SELECT
        TableName        = OBJECT_NAME(ps.object_id),
        IndexName        = ISNULL(i.name, '(heap)'),
        IndexType        = ps.index_type_desc,
        IndexDepth       = ps.index_depth,       -- levels in the tree = reads per single-row seek
        IndexLevel       = ps.index_level,       -- 0 = leaf
        PageCount        = ps.page_count,
        RowsOnLevel      = ps.record_count,
        AvgRowBytes      = CAST(ps.avg_record_size_in_bytes AS decimal(9,1)),
        RowsPerPage      = CAST(ps.record_count * 1.0 / NULLIF(ps.page_count, 0) AS decimal(9,1)),
        PageDensityPct   = CAST(ps.avg_page_space_used_in_percent AS decimal(5,1)),   -- page fullness
        LogicalFragPct   = CAST(ps.avg_fragmentation_in_percent  AS decimal(5,1)),   -- out-of-order %
        FragmentCount    = ps.fragment_count,
        AvgFragmentPages = CAST(ps.avg_fragment_size_in_pages AS decimal(9,1)),
        GhostRows        = ps.ghost_record_count,
        SizeMB           = CAST(ps.page_count * 8 / 1024.0 AS decimal(9,1)),
        FillFactorSet    = i.fill_factor          -- 0 means 100
    FROM sys.dm_db_index_physical_stats(DB_ID(), @obj, NULL, NULL, 'DETAILED') AS ps
    JOIN sys.indexes AS i
      ON i.object_id = ps.object_id AND i.index_id = ps.index_id
    WHERE ps.alloc_unit_type_desc = 'IN_ROW_DATA'
      AND (@LeafOnly = 0 OR ps.index_level = 0)
    ORDER BY ps.index_id, ps.index_level;
END;
GO

/*=============================================================================
  SETUP SECTION 0.6 - Sanity check
  EXPECT: PK_Orders leaf ~13,500 pages, ~22 rows/page, page density ~97-99%,
          fragmentation < 1%. The nonclustered indexes are much smaller
          (a few hundred to ~1,500 pages) because their rows are narrow.
=============================================================================*/
SELECT TotalRows = COUNT(*) FROM dbo.Orders;
EXEC dbo.usp_PageStats 'dbo.Orders';
GO
