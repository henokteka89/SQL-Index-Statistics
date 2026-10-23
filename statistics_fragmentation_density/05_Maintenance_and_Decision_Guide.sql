/*******************************************************************************
  INDEX INTERNALS LAB  -  FILE 05 : FIXING IT - REORGANIZE vs REBUILD,
                                    DECISION GUIDE, PRODUCTION CHECK, CLEANUP
*******************************************************************************/
USE IndexLab;
GO

/*=============================================================================
  5.0  REORGANIZE vs REBUILD - what each one really does
  -----------------------------------------------------------------------------
  ALTER INDEX ... REORGANIZE
    - Walks the leaf level and SWAPS pages so they're back in key order,
      and COMPACTS rows into fewer pages (up to the index's fill factor).
    - Always online, small transactions, can be stopped any time and you
      keep the progress made so far.
    - Works on the leaf level only. Does NOT update statistics.
    - On badly scattered big indexes it can be slow and log-heavy.

  ALTER INDEX ... REBUILD
    - Builds a brand-new copy of the index in sorted order, then drops the
      old one. Leaf AND upper levels end up perfectly ordered and filled to
      the FILLFACTOR you specify (or the stored one).
    - Updates that index's statistics WITH FULLSCAN (column statistics that
      aren't index statistics are NOT updated).
    - Needs free space roughly the size of the index (the file will grow if
      needed - which undoes a shrink).
    - Offline (blocks the table) unless WITH (ONLINE = ON), which needs
      Enterprise / Developer / Azure SQL. Rolls back fully if cancelled
      (unless RESUMABLE = ON, SQL 2017+).

  Neither one fixes a BAD DESIGN (random GUID key, rows that keep growing).
  They just reset the clock.
=============================================================================*/

/* Snapshot before. Statistics last_updated is included to prove that
   REBUILD refreshes stats and REORGANIZE doesn't.                          */
SELECT TableName        = v.t,
       PageCount        = ps.page_count,
       PageDensityPct   = CAST(ps.avg_page_space_used_in_percent AS decimal(5,1)),
       LogicalFragPct   = CAST(ps.avg_fragmentation_in_percent  AS decimal(5,1)),
       AvgFragmentPages = CAST(ps.avg_fragment_size_in_pages AS decimal(9,1)),
       StatsLastUpdated = STATS_DATE(OBJECT_ID(v.t), 1)
FROM (VALUES ('dbo.Frag_Seq'), ('dbo.Frag_Shrunk'), ('dbo.Frag_LowDensity'), ('dbo.Frag_Guid')) AS v(t)
CROSS APPLY sys.dm_db_index_physical_stats(DB_ID(), OBJECT_ID(v.t), 1, NULL, 'DETAILED') AS ps
WHERE ps.index_level = 0;
GO

/*=============================================================================
  5.1  QUADRANT B (Frag_Guid: low density + high frag) -> REORGANIZE
  -----------------------------------------------------------------------------
  EXPECT: fragmentation drops a lot, page density rises toward ~95%+ and
          page count shrinks. StatsLastUpdated does NOT change.
=============================================================================*/
WAITFOR DELAY '00:00:02';   -- so a stats timestamp change would be visible
ALTER INDEX PK_Frag_Guid ON dbo.Frag_Guid REORGANIZE;
GO
EXEC dbo.usp_PageStats 'dbo.Frag_Guid';
SELECT StatsLastUpdated = STATS_DATE(OBJECT_ID('dbo.Frag_Guid'), 1);   -- unchanged
GO

/*=============================================================================
  5.2  QUADRANT C (Frag_Shrunk: high density + high frag) -> REBUILD
  -----------------------------------------------------------------------------
  EXPECT: fragmentation ~0%, page density ~97% (it was already full),
          StatsLastUpdated = now. Check the data file size: it probably grew
          back, because the rebuild needed free space for the new copy.
=============================================================================*/
ALTER INDEX PK_Frag_Shrunk ON dbo.Frag_Shrunk REBUILD;
GO
EXEC dbo.usp_PageStats 'dbo.Frag_Shrunk';
SELECT StatsLastUpdated = STATS_DATE(OBJECT_ID('dbo.Frag_Shrunk'), 1);  -- now
SELECT name, SizeMB = size * 8 / 1024 FROM sys.database_files;
GO

/*=============================================================================
  5.3  QUADRANT D (Frag_LowDensity: low density + low frag) -> REBUILD with
       a higher fill factor
  -----------------------------------------------------------------------------
  Its fragmentation was ~0%, so a "fragmentation-only" maintenance job would
  SKIP this index forever. Page density is the problem.
  EXPECT: ~16,800 pages -> ~8,400 pages, page density ~97%.
=============================================================================*/
ALTER INDEX PK_Frag_LowDensity ON dbo.Frag_LowDensity REBUILD WITH (FILLFACTOR = 100);
GO
EXEC dbo.usp_PageStats 'dbo.Frag_LowDensity';
GO

/*=============================================================================
  5.4  RE-MEASURE: everyone should now look like the ideal table
=============================================================================*/
EXEC dbo.usp_ScanTest 'dbo.Frag_Seq',        1;
EXEC dbo.usp_ScanTest 'dbo.Frag_Shrunk',     1;
EXEC dbo.usp_ScanTest 'dbo.Frag_LowDensity', 1;
EXEC dbo.usp_ScanTest 'dbo.Frag_Guid',       1;
GO

/*=============================================================================
  5.5  EXPERIMENT: does a lower fill factor help a GUID key?
  -----------------------------------------------------------------------------
  Rebuild Frag_Guid at FILLFACTOR 100, add 20,000 random rows, measure.
  Then rebuild at FILLFACTOR 80, add 20,000 more, measure again.
  EXPECT: at 100, the new inserts split pages almost immediately ->
          fragmentation shoots back up. At 80, there's room on each page,
          so far fewer splits happen until pages fill again - fragmentation
          rises much more slowly, at the price of ~20% more pages up front.
  This is the right use of fill factor: on indexes with random inserts,
  sized to how much they grow between maintenance windows.
=============================================================================*/
ALTER INDEX PK_Frag_Guid ON dbo.Frag_Guid REBUILD WITH (FILLFACTOR = 100);
GO
SET NOCOUNT ON;
DECLARE @i int = 0;
WHILE @i < 200 BEGIN INSERT dbo.Frag_Guid (Payload) SELECT TOP (100) -1 FROM sys.all_objects; SET @i += 1; END;
SET NOCOUNT OFF;
EXEC dbo.usp_PageStats 'dbo.Frag_Guid';    -- FF100 + 20k inserts
GO
ALTER INDEX PK_Frag_Guid ON dbo.Frag_Guid REBUILD WITH (FILLFACTOR = 80);
GO
SET NOCOUNT ON;
DECLARE @i int = 0;
WHILE @i < 200 BEGIN INSERT dbo.Frag_Guid (Payload) SELECT TOP (100) -2 FROM sys.all_objects; SET @i += 1; END;
SET NOCOUNT OFF;
EXEC dbo.usp_PageStats 'dbo.Frag_Guid';    -- FF80 + 20k inserts
GO

/*=============================================================================
  5.6  THE CHEAT SHEET
=============================================================================

  A) PHYSICAL: PAGE DENSITY x FRAGMENTATION
  ---------------------------------------------------------------------------
  Page dens. | Frag  | What it means          | Typical cause         | Fix
  -----------+-------+------------------------+-----------------------+-----------------
  HIGH       | LOW   | Ideal                  | Ever-increasing key,  | Nothing
             |       |                        | append-only inserts   |
  HIGH       | HIGH  | Full pages, scattered. | Shrinking data files; | Rebuild (or
             |       | Same logical reads;    | interleaved growth    | reorganize) IF big
             |       | more/smaller disk I/O  |                       | scans read from
             |       | on cold scans.         |                       | disk. Stop shrinking.
  LOW        | LOW   | In order but wasteful: | Low fill factor,      | Rebuild/reorganize
             |       | more pages, more reads | mass deletes, rows    | to compact. Review
             |       | AND more memory, even  | shrunk by updates     | the fill factor.
             |       | when cached.           |                       | Frag-only jobs MISS this.
  LOW        | HIGH  | Worst for scans: more  | Random keys (NEWID),  | Rebuild; consider
             |       | pages + small I/Os +   | rows that grow on     | lower fill factor or
             |       | page splits on insert  | UPDATE                | a sequential key
             |       | (extra log, latching). |                       |

  B) STATISTICS DENSITY x PHYSICAL STATE (how they meet)
  ---------------------------------------------------------------------------
  Statistics density decides the plan; physical state decides the cost of it.

  - LOW stats density (selective column, e.g. Email, CustomerID):
      queries do small SEEKS. Each seek reads ~IndexDepth pages, no matter
      how fragmented the leaf is. Page density matters only a little (maybe
      a slightly deeper/bigger index). Defragmenting these indexes usually
      buys you very little.
  - HIGH stats density (non-selective column, e.g. Status, IsActive):
      queries SCAN (or seek and then read a large range). Now every extra
      page from low page density is paid on every execution, and
      fragmentation slows the scan whenever it comes from disk.
      These are the indexes where maintenance is worth it - and where a
      covering index (INCLUDE) can turn a big scan into a small one.
  - Skewed high-density columns: the density AVERAGE can mislead the
      optimizer (Lab 01, 1.5). Fix with better statistics / OPTION
      (RECOMPILE) / filtered indexes - NOT with defragmentation.

  C) RULES OF THUMB A JUNIOR DBA CAN USE
  ---------------------------------------------------------------------------
  1. Ignore indexes under ~1,000 pages for fragmentation work.
  2. Look at page density AND fragmentation, never fragmentation alone.
  3. The old "5-30% reorganize, >30% rebuild" thresholds are a starting
     point from an era of spinning disks, not a law. Measure: is the index
     scanned a lot (usage stats)? Is it read from disk (physical reads /
     read-ahead in STATISTICS IO, PAGEIOLATCH waits)? If not, fragmentation
     probably isn't your problem.
  4. Rebuild updates index stats with a full scan; reorganize doesn't. After
     a reorganize, consider UPDATE STATISTICS.
  5. Don't shrink data files as routine maintenance.
  6. Tune queries with LOGICAL reads. Physical reads depend on cache luck.
  7. A seek is not automatically good and a scan is not automatically bad.
=============================================================================*/

/*=============================================================================
  5.7  PRODUCTION-SAFE CHECK (run in any user database)
  -----------------------------------------------------------------------------
  SAMPLED mode gives page density without reading every page. On very large
  databases run it off-hours, or use LIMITED (no page density) first.
  The "Suggestion" column is a conversation starter, not an automatic action.
=============================================================================*/
SELECT SchemaName       = OBJECT_SCHEMA_NAME(ps.object_id),
       TableName        = OBJECT_NAME(ps.object_id),
       IndexName        = i.name,
       ps.index_type_desc,
       ps.page_count,
       PageDensityPct   = CAST(ps.avg_page_space_used_in_percent AS decimal(5,1)),
       LogicalFragPct   = CAST(ps.avg_fragmentation_in_percent  AS decimal(5,1)),
       i.fill_factor,
       Scans            = ISNULL(us.user_scans, 0),
       Seeks            = ISNULL(us.user_seeks, 0),
       Suggestion = CASE
           WHEN ps.page_count < 1000                       THEN 'Ignore - too small to matter'
           WHEN ps.avg_page_space_used_in_percent < 70
            AND ps.avg_fragmentation_in_percent  >= 30     THEN 'Low density + high frag: rebuild; check key design / fill factor'
           WHEN ps.avg_page_space_used_in_percent < 70     THEN 'Low page density: wasted pages - rebuild/reorganize to compact'
           WHEN ps.avg_fragmentation_in_percent >= 30      THEN 'High frag, pages full: matters only if scanned from disk'
           WHEN ps.avg_fragmentation_in_percent >= 5       THEN 'Moderate frag: usually fine; reorganize if heavily scanned'
           ELSE                                                 'OK'
       END
FROM sys.dm_db_index_physical_stats(DB_ID(), NULL, NULL, NULL, 'SAMPLED') AS ps
JOIN sys.indexes AS i
  ON i.object_id = ps.object_id AND i.index_id = ps.index_id
LEFT JOIN sys.dm_db_index_usage_stats AS us
  ON us.database_id = DB_ID() AND us.object_id = ps.object_id AND us.index_id = ps.index_id
WHERE ps.index_id > 0
  AND ps.alloc_unit_type_desc = 'IN_ROW_DATA'
  AND ps.index_level = 0
  AND OBJECTPROPERTY(ps.object_id, 'IsUserTable') = 1
ORDER BY ps.page_count DESC;
GO

/*=============================================================================
  5.8  CLEANUP (uncomment when you're done with the lab)
=============================================================================*/
-- USE master;
-- ALTER DATABASE IndexLab SET SINGLE_USER WITH ROLLBACK IMMEDIATE;
-- DROP DATABASE IndexLab;
