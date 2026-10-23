/*******************************************************************************
  INDEX INTERNALS LAB  -  FILE 03 : FRAGMENTATION - THE FOUR QUADRANTS
  -----------------------------------------------------------------------------
  Goal: build four tables with the SAME rows but different physical layouts,
        so you can see page density and fragmentation vary independently:

                          LOW fragmentation          HIGH fragmentation
                       +--------------------------+--------------------------+
     HIGH page density |  A. Frag_Seq             |  C. Frag_Shrunk          |
     (pages full)      |  ideal: in order + full  |  full pages, scattered   |
                       |  cause: IDENTITY key     |  cause: DBCC SHRINKFILE  |
                       +--------------------------+--------------------------+
     LOW page density  |  D. Frag_LowDensity      |  B. Frag_Guid            |
     (pages part-empty)|  in order, half empty    |  scattered AND part-empty|
                       |  cause: FILLFACTOR 50 /  |  cause: random key       |
                       |  deletes                 |  (NEWID) -> page splits  |
                       +--------------------------+--------------------------+

  Each table: ~200,000 rows of ~330 bytes (~24 rows per full page).
  IMPORTANT: run the sections IN ORDER. Section 3.4 depends on where pages
  were allocated in the file by the earlier sections.
*******************************************************************************/
USE IndexLab;
GO

/*=============================================================================
  3.1  CREATE TABLE A (sequential key) and TABLE B (random GUID key)
=============================================================================*/
DROP TABLE IF EXISTS dbo.Frag_Seq, dbo.Frag_Guid, dbo.Frag_LowDensity,
                     dbo.Frag_Shrunk, dbo.ShrinkFiller;
GO
CREATE TABLE dbo.Frag_Seq
(
    ID      int IDENTITY(1,1) NOT NULL CONSTRAINT PK_Frag_Seq PRIMARY KEY CLUSTERED,
    Payload int        NOT NULL,
    Filler  char(300)  NOT NULL CONSTRAINT DF_Frag_Seq_Filler DEFAULT ('x')
);
CREATE TABLE dbo.Frag_Guid
(
    ID      uniqueidentifier NOT NULL CONSTRAINT DF_Frag_Guid_ID DEFAULT (NEWID())
                                      CONSTRAINT PK_Frag_Guid PRIMARY KEY CLUSTERED,
    Payload int        NOT NULL,
    Filler  char(300)  NOT NULL CONSTRAINT DF_Frag_Guid_Filler DEFAULT ('x')
);
GO

/*=============================================================================
  3.2  LOAD BOTH THE SAME WAY: 2,000 small inserts of 100 rows
  -----------------------------------------------------------------------------
  We insert in small batches on purpose - that's how OLTP apps insert.
  (One giant INSERT...SELECT would let SQL Server SORT the GUIDs first and
   hide the problem.)

  Frag_Seq : every new ID is bigger than the last -> rows always go on the
             LAST page. When it fills, a fresh page is added at the end.
             No rows move. Pages stay full and in order.
  Frag_Guid: every NEWID() lands at a RANDOM place in the key order -> it
             usually goes into a page in the middle that's already full ->
             PAGE SPLIT: half the rows move to a new page allocated wherever
             there's free space. Pages end up ~half to 3/4 full and out of
             order.
  Takes ~30-90 seconds.
=============================================================================*/
SET NOCOUNT ON;
DECLARE @i int = 0;
WHILE @i < 2000
BEGIN
    INSERT dbo.Frag_Seq  (Payload) SELECT TOP (100) @i FROM sys.all_objects;
    INSERT dbo.Frag_Guid (Payload) SELECT TOP (100) @i FROM sys.all_objects;
    SET @i += 1;
END;
SET NOCOUNT OFF;
GO

/* PAGE ALLOCATIONS (includes splits)
   leaf_allocation_count counts new leaf pages: end-of-index "good" page adds
   for Frag_Seq, and mostly mid-index splits for Frag_Guid.
   EXPECT: Frag_Seq allocations ~= its page count (~8,400).
           Frag_Guid allocations noticeably higher, with more pages at the end.
   (These counters live in memory and reset on restart / metadata eviction.) */
SELECT TableName = OBJECT_NAME(os.object_id),
       os.leaf_insert_count,
       os.leaf_allocation_count,      -- new leaf pages (page splits included)
       os.nonleaf_allocation_count
FROM sys.dm_db_index_operational_stats(DB_ID(), NULL, NULL, NULL) AS os
WHERE os.object_id IN (OBJECT_ID('dbo.Frag_Seq'), OBJECT_ID('dbo.Frag_Guid'))
  AND os.index_id = 1;
GO

/* EXPECT:
     Frag_Seq : ~8,400 pages, page density ~97%, frag ~1%,  big AvgFragmentPages
     Frag_Guid: ~11,000-12,000 pages, page density ~65-75%, frag ~95-99%,
                AvgFragmentPages ~1  (almost every page is its own fragment)
   Same 200,000 rows. The GUID table is ~40% bigger AND fully scrambled.  */
EXEC dbo.usp_PageStats 'dbo.Frag_Seq';
EXEC dbo.usp_PageStats 'dbo.Frag_Guid';
GO

/*=============================================================================
  3.3  TABLE D: low page density, low fragmentation (FILLFACTOR = 50)
  -----------------------------------------------------------------------------
  Copy the sequential data and build the clustered index half-full.
  EXPECT: ~16,800 pages, page density ~48%, fragmentation ~0%.
=============================================================================*/
SELECT ID, Payload, Filler INTO dbo.Frag_LowDensity FROM dbo.Frag_Seq;
ALTER TABLE dbo.Frag_LowDensity
    ADD CONSTRAINT PK_Frag_LowDensity PRIMARY KEY CLUSTERED (ID) WITH (FILLFACTOR = 50);
GO
EXEC dbo.usp_PageStats 'dbo.Frag_LowDensity';
GO

/*=============================================================================
  3.4  TABLE C: high page density, HIGH fragmentation (the shrink trap)
  -----------------------------------------------------------------------------
  How we do it:
   1. Create a ~100 MB filler table (it takes the next free space in the file).
   2. Build Frag_Shrunk perfectly (full pages, in order) - it lands AFTER the
      filler, near the end of the data file.
   3. Drop the filler -> a big hole of free space before Frag_Shrunk.
   4. DBCC SHRINKFILE. Shrink works from the END of the file backwards: it
      takes the LAST page and moves it to the FIRST free slot, then the
      second-last page to the next free slot, and so on. The highest keys
      are moved first, so the table ends up stored roughly BACKWARDS.
  Pages are not split or emptied - just moved. So page density stays ~97%
  but logical fragmentation goes to ~90-100%.

  REAL-WORLD LESSON: this is why regular/automatic shrinking of data files
  is a bad habit. It fragments indexes; then the index rebuild needs free
  space, grows the file again, and the next shrink fragments it again.
  Exact results vary by what else is in the file - the pattern is reliable.
=============================================================================*/
CREATE TABLE dbo.ShrinkFiller (c char(8000) NOT NULL CONSTRAINT DF_ShrinkFiller DEFAULT ('a'));
INSERT dbo.ShrinkFiller (c) SELECT 'a' FROM dbo.fn_Numbers(12800);   -- 1 row per page, ~100 MB
GO
SELECT ID, Payload, Filler INTO dbo.Frag_Shrunk FROM dbo.Frag_Seq;
ALTER TABLE dbo.Frag_Shrunk
    ADD CONSTRAINT PK_Frag_Shrunk PRIMARY KEY CLUSTERED (ID) WITH (FILLFACTOR = 100);
GO
EXEC dbo.usp_PageStats 'dbo.Frag_Shrunk';   -- BEFORE: ~97% full, frag ~0%
GO
DROP TABLE dbo.ShrinkFiller;
GO
DBCC SHRINKFILE (1, 1);    -- file_id 1 = primary data file; shrink as far as possible
GO
EXEC dbo.usp_PageStats 'dbo.Frag_Shrunk';   -- AFTER: still ~97% full, frag ~90-100%
GO

/*=============================================================================
  3.5  SIDE-BY-SIDE: THE FOUR QUADRANTS
  -----------------------------------------------------------------------------
  EXPECT (approx):
    Table            Pages    PageDensity  LogicalFrag  AvgFragmentPages
    Frag_Seq         ~8,400     ~97%          ~1%         hundreds+
    Frag_Shrunk      ~8,400     ~97%         ~95%+        ~1
    Frag_LowDensity ~16,800     ~48%          ~0%         hundreds+
    Frag_Guid       ~11,500     ~70%         ~99%         ~1

  HOW TO READ THIS:
   - PageCount vs Frag_Seq tells you the cost in LOGICAL reads (memory).
     Frag_Shrunk = same as ideal. Frag_LowDensity = double. Frag_Guid = +40%.
   - LogicalFrag / AvgFragmentPages tell you how the pages come off DISK.
     Frag_Seq and Frag_LowDensity can be read in long contiguous runs.
     Frag_Shrunk and Frag_Guid need many small reads.
   - Lab 04 measures exactly that.
=============================================================================*/
SELECT TableName        = v.t,
       Quadrant         = v.q,
       PageCount        = ps.page_count,
       RowsOnLeaf       = ps.record_count,
       PageDensityPct   = CAST(ps.avg_page_space_used_in_percent AS decimal(5,1)),
       LogicalFragPct   = CAST(ps.avg_fragmentation_in_percent  AS decimal(5,1)),
       FragmentCount    = ps.fragment_count,
       AvgFragmentPages = CAST(ps.avg_fragment_size_in_pages AS decimal(9,1))
FROM (VALUES ('dbo.Frag_Seq',        'A: high density / low frag  (ideal)'),
             ('dbo.Frag_Shrunk',     'C: high density / HIGH frag (shrink)'),
             ('dbo.Frag_LowDensity', 'D: LOW density  / low frag  (fill factor/deletes)'),
             ('dbo.Frag_Guid',       'B: LOW density  / HIGH frag (page splits)')) AS v(t, q)
CROSS APPLY sys.dm_db_index_physical_stats(DB_ID(), OBJECT_ID(v.t), 1, NULL, 'DETAILED') AS ps
WHERE ps.index_level = 0;
GO

/*=============================================================================
  3.6  (OPTIONAL) SEE THE PAGE CHAIN WITH YOUR OWN EYES
  -----------------------------------------------------------------------------
  sys.dm_db_database_page_allocations is UNDOCUMENTED (fine for a lab, don't
  build production tooling on it). It lists every page with its
  next_page_page_id = the next page in KEY order.

  Jump = NextPage - ThisPage:
     1         -> the next page in key order is physically right next to it
     other     -> the scan must jump somewhere else in the file
     negative  -> jumps BACKWARDS (that's what counts as "out of order")

  EXPECT: Frag_Seq mostly Jump = 1 (occasional jumps between extents).
          Frag_Shrunk mostly Jump = -1  (stored backwards!).
          Frag_Guid   random jumps all over the place.
=============================================================================*/
SELECT TOP (25) TableName = 'Frag_Seq',
       ThisPage = allocated_page_page_id, NextPage = next_page_page_id,
       Jump     = next_page_page_id - allocated_page_page_id
FROM sys.dm_db_database_page_allocations(DB_ID(), OBJECT_ID('dbo.Frag_Seq'), 1, NULL, 'DETAILED')
WHERE is_allocated = 1 AND page_type_desc = 'DATA_PAGE' AND next_page_page_id IS NOT NULL
ORDER BY allocated_page_page_id;

SELECT TOP (25) TableName = 'Frag_Shrunk',
       ThisPage = allocated_page_page_id, NextPage = next_page_page_id,
       Jump     = next_page_page_id - allocated_page_page_id
FROM sys.dm_db_database_page_allocations(DB_ID(), OBJECT_ID('dbo.Frag_Shrunk'), 1, NULL, 'DETAILED')
WHERE is_allocated = 1 AND page_type_desc = 'DATA_PAGE' AND next_page_page_id IS NOT NULL
ORDER BY allocated_page_page_id;

SELECT TOP (25) TableName = 'Frag_Guid',
       ThisPage = allocated_page_page_id, NextPage = next_page_page_id,
       Jump     = next_page_page_id - allocated_page_page_id
FROM sys.dm_db_database_page_allocations(DB_ID(), OBJECT_ID('dbo.Frag_Guid'), 1, NULL, 'DETAILED')
WHERE is_allocated = 1 AND page_type_desc = 'DATA_PAGE' AND next_page_page_id IS NOT NULL
ORDER BY allocated_page_page_id;
GO

/*  TAKEAWAYS FROM LAB 03
    - Page density and fragmentation are INDEPENDENT. All four combinations
      happen in real life, each with a different cause.
    - Random keys (GUIDs) cause page splits -> BOTH low density and high frag.
    - Shrink causes high frag with full pages.
    - Low fill factor / deletes cause low density with no frag.
    - Ignore fragmentation on small indexes (< ~1,000 pages): they're read
      in a handful of I/Os anyway and the % jumps around meaninglessly.     */
