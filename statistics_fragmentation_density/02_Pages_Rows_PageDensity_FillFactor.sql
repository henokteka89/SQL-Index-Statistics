/*******************************************************************************
  INDEX INTERNALS LAB  -  FILE 02 : PAGES, ROWS, PAGE DENSITY, FILL FACTOR
  -----------------------------------------------------------------------------
  Goal: understand page count and PAGE density (how full pages are), and prove
        that half-empty pages cost real reads even when fragmentation is 0%.
*******************************************************************************/
USE IndexLab;
GO

/*=============================================================================
  2.1  CHEAP SIZE NUMBERS: sys.dm_db_partition_stats
  -----------------------------------------------------------------------------
  This DMV is instant (it reads metadata, not pages). Use it on production
  for "how big is this table/index?"

    row_count              : rows in the index
    in_row_data_page_count : LEAF pages (data pages for a heap)
    used_page_count        : all pages actually in use, incl. upper tree
                             levels and IAM (allocation map) pages
    reserved_page_count    : pages allocated to the object, used or not

  EXPECT: PK_Orders ~13,600 leaf pages. The NC indexes are a small fraction
  because each NC row is just key + OrderID (a few bytes) instead of ~355.
=============================================================================*/
SELECT IndexName   = i.name,
       i.type_desc,
       ps.row_count,
       LeafPages   = ps.in_row_data_page_count,
       ps.used_page_count,
       ps.reserved_page_count,
       UsedMB      = CAST(ps.used_page_count * 8 / 1024.0 AS decimal(9,1)),
       RowsPerLeafPage = CAST(ps.row_count * 1.0 / NULLIF(ps.in_row_data_page_count,0) AS decimal(9,1))
FROM sys.dm_db_partition_stats AS ps
JOIN sys.indexes AS i ON i.object_id = ps.object_id AND i.index_id = ps.index_id
WHERE ps.object_id = OBJECT_ID('dbo.Orders')
ORDER BY i.index_id;
GO

/*=============================================================================
  2.2  EVERY LEVEL OF THE B-TREE
  -----------------------------------------------------------------------------
  EXPECT for PK_Orders (numbers approximate):
     level 0 (leaf)  ~13,600 pages   ~300,000 rows   ~22 rows/page
     level 1         ~20-30 pages    one row per leaf page (key + page pointer)
     level 2 (root)  1 page
     IndexDepth = 3   -> a single-row seek on OrderID reads exactly 3 pages.

  DO THE MATH YOURSELF:
     AvgRowBytes ~355. Each row also needs 2 bytes in the slot array.
     8,096 / 357 ~= 22.7 -> 22 whole rows fit per page.
     300,000 / 22 ~= 13,636 pages. Compare with PageCount.
     22 x 357 = 7,854 bytes used of 8,096 -> ~97% page density.
     So even a "perfect" table isn't always 100% full - leftover space that
     can't fit one more row is normal.

  Upper-level rows are tiny (key + 6-byte page pointer), so hundreds fit per
  page. That's why depth stays 3-4 even for tables with hundreds of millions
  of rows.
=============================================================================*/
EXEC dbo.usp_PageStats 'dbo.Orders', 0;
GO

/*=============================================================================
  2.3  FILL FACTOR: same rows, different page density
  -----------------------------------------------------------------------------
  Make 3 identical copies of Orders and build each with a different fill
  factor. Same 300,000 rows. Fragmentation will be ~0% on all of them,
  because each was just built in order.
=============================================================================*/
DROP TABLE IF EXISTS dbo.Orders_FF100, dbo.Orders_FF80, dbo.Orders_FF50;
GO
SELECT * INTO dbo.Orders_FF100 FROM dbo.Orders;
SELECT * INTO dbo.Orders_FF80  FROM dbo.Orders;
SELECT * INTO dbo.Orders_FF50  FROM dbo.Orders;
GO
CREATE UNIQUE CLUSTERED INDEX CIX ON dbo.Orders_FF100 (OrderID) WITH (FILLFACTOR = 100);
CREATE UNIQUE CLUSTERED INDEX CIX ON dbo.Orders_FF80  (OrderID) WITH (FILLFACTOR = 80);
CREATE UNIQUE CLUSTERED INDEX CIX ON dbo.Orders_FF50  (OrderID) WITH (FILLFACTOR = 50);
GO

/* EXPECT:
     Table          Pages     PageDensity   LogicalFrag
     Orders_FF100   ~13,600     ~97%          ~0%
     Orders_FF80    ~17,700     ~78%          ~0%
     Orders_FF50    ~30,000     ~48%          ~0%
   (FF50 holds ~10 rows per page instead of 22.)

   This is the "LOW page density + LOW fragmentation" case:
   pages are perfectly in order, they're just half empty.               */
SELECT TableName      = v.t,
       PageCount      = ps.page_count,
       RowsOnLeaf     = ps.record_count,
       RowsPerPage    = CAST(ps.record_count * 1.0 / ps.page_count AS decimal(9,1)),
       PageDensityPct = CAST(ps.avg_page_space_used_in_percent AS decimal(5,1)),
       LogicalFragPct = CAST(ps.avg_fragmentation_in_percent  AS decimal(5,1)),
       SizeMB         = CAST(ps.page_count * 8 / 1024.0 AS decimal(9,1))
FROM (VALUES ('dbo.Orders_FF100'), ('dbo.Orders_FF80'), ('dbo.Orders_FF50')) AS v(t)
CROSS APPLY sys.dm_db_index_physical_stats(DB_ID(), OBJECT_ID(v.t), 1, NULL, 'DETAILED') AS ps
WHERE ps.index_level = 0;
GO

/* Now scan all three. Same result, same rows.
   EXPECT logical reads: ~13,600 vs ~17,700 vs ~30,000.

   LESSON: logical reads (and buffer pool memory, and backup size, and
   CHECKDB time...) scale with PAGE COUNT. Low page density costs you
   every single time the table is scanned, in memory or not.
   A low fill factor is a trade: fewer future page splits vs more pages
   today. Don't lower it "just because" - lower it only on indexes that
   actually suffer from splits (random-key inserts, growing updates).   */
SET STATISTICS IO ON;
SELECT SUM(Amount) FROM dbo.Orders_FF100;
SELECT SUM(Amount) FROM dbo.Orders_FF80;
SELECT SUM(Amount) FROM dbo.Orders_FF50;
SET STATISTICS IO OFF;
GO

/*=============================================================================
  2.4  DELETES CREATE LOW PAGE DENSITY (without any fragmentation)
  -----------------------------------------------------------------------------
  A very common real-world case: a purge job deletes old/odd rows across the
  whole table. The pages stay allocated; they just get emptier.
=============================================================================*/
DROP TABLE IF EXISTS dbo.Orders_Deleted;
SELECT * INTO dbo.Orders_Deleted FROM dbo.Orders;
CREATE UNIQUE CLUSTERED INDEX CIX ON dbo.Orders_Deleted (OrderID) WITH (FILLFACTOR = 100);
GO
EXEC dbo.usp_PageStats 'dbo.Orders_Deleted';     -- BEFORE: ~13,600 pages, ~97% full
GO
DELETE dbo.Orders_Deleted WHERE OrderID % 2 = 0; -- remove every other row
GO

/* GHOST RECORDS: a DELETE doesn't physically wipe the row immediately. It
   marks it as a "ghost" and a background task (ghost cleanup) removes it a
   little later. Right after the delete you may see GhostRows > 0.
   Wait a few seconds (or scan the table) and re-check.                   */
EXEC dbo.usp_PageStats 'dbo.Orders_Deleted';
WAITFOR DELAY '00:00:10';
SELECT COUNT(*) FROM dbo.Orders_Deleted;
EXEC dbo.usp_PageStats 'dbo.Orders_Deleted';
/* EXPECT AFTER: rows ~150,000, PageCount STILL ~13,600, PageDensity ~48%,
                 LogicalFrag still ~0%.
   Fragmentation-based maintenance scripts that only look at
   avg_fragmentation_in_percent would say "this index is fine". It isn't:
   you're reading twice the pages you need.                               */
GO

SET STATISTICS IO ON;
SELECT SUM(Amount) FROM dbo.Orders_Deleted;   -- EXPECT ~13,600 reads for half the rows
SET STATISTICS IO OFF;
GO

-- Fix it: rebuild compacts rows back into full pages.
ALTER INDEX CIX ON dbo.Orders_Deleted REBUILD;
GO
EXEC dbo.usp_PageStats 'dbo.Orders_Deleted';  -- EXPECT ~6,800 pages, ~97% full
SET STATISTICS IO ON;
SELECT SUM(Amount) FROM dbo.Orders_Deleted;   -- EXPECT ~6,800 reads
SET STATISTICS IO OFF;
GO

/*  TAKEAWAYS FROM LAB 02
    - Page count is what you pay for. Rows per page depends on row width
      and on how full pages are (page density).
    - Low page density can come from: low fill factor, deletes, page splits,
      or updates that shrink rows.
    - Low page density + 0% fragmentation is real waste that fragmentation
      percentages alone will never show you. Always look at BOTH columns.   */
