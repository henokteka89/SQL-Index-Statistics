/*******************************************************************************
  INDEX INTERNALS LAB  -  FILE 01 : STATISTICS DENSITY, SELECTIVITY, SEEK vs SCAN
  -----------------------------------------------------------------------------
  Goal: see how STATISTICS density (distinct values) drives the optimizer to
        choose a seek or a scan, what a key lookup costs, and where the
        "tipping point" is.
  Turn on: Include Actual Execution Plan (Ctrl+M). Read the Messages tab.
*******************************************************************************/
USE IndexLab;
GO

/*=============================================================================
  1.1  LOOK AT THE DENSITY VECTOR
  -----------------------------------------------------------------------------
  DBCC SHOW_STATISTICS has 3 parts: header, density vector, histogram.
  Here we only want the density vector.

  EXPECT:
    IX_Orders_CustomerID  "All density" for CustomerID          = 5E-05   (1/20,000)
                                         for CustomerID, OrderID = 3.3E-06 (1/300,000)
    IX_Orders_Status      Status                                 = 0.2     (1/5)
    IX_Orders_IsActive    IsActive                               = 0.5     (1/2)
    UX_Orders_Email       Email                                  = 3.3E-06

  NOTES:
  - "All density" = 1 / distinct values of that column combination.
  - Why is there a second row "CustomerID, OrderID"? Every nonclustered index
    secretly carries the clustered key (OrderID) as its row pointer, so SQL
    Server also tracks the density of the combination. CustomerID+OrderID is
    unique, so its density is 1/300,000.
  - "Average Length" = average bytes of the key - matters for index size.
  - HOW THE OPTIMIZER USES IT: when it does NOT know the value you're searching
    for (a local variable, an OPTIMIZE FOR UNKNOWN, etc.) it estimates:
          estimated rows = All density x total rows
    CustomerID: 0.00005 x 300,000 = 15 rows   -> seek looks cheap
    Status    : 0.2     x 300,000 = 60,000    -> scan looks cheaper
=============================================================================*/
DBCC SHOW_STATISTICS ('dbo.Orders', 'IX_Orders_CustomerID') WITH DENSITY_VECTOR;
DBCC SHOW_STATISTICS ('dbo.Orders', 'IX_Orders_Status')     WITH DENSITY_VECTOR;
DBCC SHOW_STATISTICS ('dbo.Orders', 'IX_Orders_IsActive')   WITH DENSITY_VECTOR;
DBCC SHOW_STATISTICS ('dbo.Orders', 'UX_Orders_Email')      WITH DENSITY_VECTOR;
GO

/*=============================================================================
  1.2  CALCULATE DENSITY YOURSELF (for ANY column, even without an index)
  -----------------------------------------------------------------------------
  This query computes density for every column so you can see the spectrum
  from very high density (IsActive) to very low density (Email).

  The "Verdict" thresholds are rough teaching labels, NOT rules. The real
  seek/scan decision is cost-based and depends heavily on whether the index
  COVERS the query (has all the columns it needs) - see 1.4 and 1.7.
=============================================================================*/
WITH d AS
(
    SELECT TotalRows  = COUNT(*),
           dOrderID   = COUNT(DISTINCT OrderID),
           dCustomer  = COUNT(DISTINCT CustomerID),
           dStatus    = COUNT(DISTINCT Status),
           dIsActive  = COUNT(DISTINCT IsActive),
           dRegion    = COUNT(DISTINCT Region),
           dOrderDate = COUNT(DISTINCT OrderDate),
           dEmail     = COUNT(DISTINCT Email)
    FROM dbo.Orders
)
SELECT v.ColumnName,
       v.DistinctValues,
       d.TotalRows,
       Density          = CAST(1.0 / v.DistinctValues AS decimal(18,10)),
       AvgRowsPerValue  = d.TotalRows / v.DistinctValues,     -- = density x rows
       Verdict = CASE
                   WHEN 1.0 / v.DistinctValues >= 0.01   THEN 'HIGH density  -> low selectivity  -> scan-prone'
                   WHEN 1.0 / v.DistinctValues >= 0.0001 THEN 'MEDIUM density'
                   ELSE                                       'LOW density   -> high selectivity -> seek-friendly'
                 END
FROM d
CROSS APPLY (VALUES ('OrderID',    d.dOrderID),
                    ('CustomerID', d.dCustomer),
                    ('Status',     d.dStatus),
                    ('IsActive',   d.dIsActive),
                    ('Region',     d.dRegion),
                    ('OrderDate',  d.dOrderDate),
                    ('Email',      d.dEmail)) AS v(ColumnName, DistinctValues)
ORDER BY Density DESC;
GO

/*=============================================================================
  1.3  DENSITY IS AN AVERAGE - THE HISTOGRAM SHOWS THE TRUTH (skew)
  -----------------------------------------------------------------------------
  IsActive density = 0.5 says "each value has about half the rows".
  But the real data: IsActive = 1 -> 297,000 rows, IsActive = 0 -> 3,000 rows.

  EXPECT (histogram):  RANGE_HI_KEY 0 -> EQ_ROWS 3000
                       RANGE_HI_KEY 1 -> EQ_ROWS 297000

  NOTE: the histogram (up to 200 steps) records how many rows match specific
  values. When the optimizer can SEE your value (a literal, or a parameter
  it sniffs), it uses the histogram. When it can't, it falls back to the
  density average. On skewed data those two guesses can be wildly different.
=============================================================================*/
DBCC SHOW_STATISTICS ('dbo.Orders', 'IX_Orders_IsActive') WITH HISTOGRAM;
DBCC SHOW_STATISTICS ('dbo.Orders', 'IX_Orders_Status')   WITH HISTOGRAM;
GO

/*=============================================================================
  1.4  LOW density column -> SEEK.   HIGH density column -> SCAN.
  -----------------------------------------------------------------------------
  Run each query separately and record: plan operators + logical reads.
=============================================================================*/
SET STATISTICS IO, TIME ON;
GO

-- (a) LOW density: CustomerID = 500 returns 15 rows.
-- EXPECT plan : Index Seek (IX_Orders_CustomerID) + Key Lookup (PK_Orders)
--               joined with Nested Loops.
-- EXPECT reads: ~45-50.  = ~2-3 pages to seek the NC index
--                        + 15 key lookups x 3 levels of the clustered index.
-- Each lookup lands on a DIFFERENT data page, because customer 500's orders
-- are spread across the whole table (OrderIDs 499, 20499, 40499 ...).
SELECT * FROM dbo.Orders WHERE CustomerID = 500;
GO

-- (b) HIGH density: Status = 2 returns 60,000 rows (20% of the table).
-- EXPECT plan : Clustered Index Scan (PK_Orders). The IX_Orders_Status
--               index exists but the optimizer IGNORES it.
-- EXPECT reads: ~13,600 = every leaf page of the table, read once.
SELECT * FROM dbo.Orders WHERE Status = 2;
GO

-- (c) Force the "seek" on the high-density index to see WHY it was ignored.
-- EXPECT reads: ~180,000+ ! = 60,000 key lookups x 3 levels each,
-- plus the NC index pages. That's 13x MORE pages than scanning everything.
-- LESSON: a seek is NOT automatically better. On a high-density column with
--         key lookups, the scan wins by a mile.
SELECT * FROM dbo.Orders WITH (INDEX (IX_Orders_Status)) WHERE Status = 2;
GO

-- (d) Same high-density index, but the query only needs the indexed column.
-- No lookups needed -> the index COVERS the query.
-- EXPECT plan : Index Seek on IX_Orders_Status (no Key Lookup)
-- EXPECT reads: ~100-ish (60,000 narrow index rows packed ~600 per page)
-- LESSON: high-density columns are bad for "find me rows" seeks with lookups,
--         but an index on them can still be very useful when it covers the
--         query, or as part of a multi-column index.
SELECT COUNT(*) FROM dbo.Orders WHERE Status = 2;
GO

/*=============================================================================
  1.5  SKEW + DENSITY: literal vs local variable
  -----------------------------------------------------------------------------
  Compare "Estimated Number of Rows" vs "Actual Number of Rows" on the
  first operator in each plan (hover over it). Run these 3 together.

  (a) literal 0          -> optimizer reads histogram -> estimate 3,000 (correct)
  (b) local variable @a  -> value unknown at compile time -> uses DENSITY:
                            0.5 x 300,000 = 150,000 estimated, 3,000 actual.
                            It probably chooses a full scan because it thinks
                            half the table is coming back.
  (c) OPTION (RECOMPILE) -> SQL Server compiles with the variable's actual
                            value, so it can use the histogram again.

  LESSON for junior DBAs: when you see a big estimate vs actual gap, ask
  "did the optimizer use the density average instead of the histogram?"
  Local variables, OPTIMIZE FOR UNKNOWN and some parameter sniffing cases
  all lead to the density average.
=============================================================================*/
SELECT * FROM dbo.Orders WHERE IsActive = 0;

DECLARE @a bit = 0;
SELECT * FROM dbo.Orders WHERE IsActive = @a;
SELECT * FROM dbo.Orders WHERE IsActive = @a OPTION (RECOMPILE);
GO

/*=============================================================================
  1.6  FIND THE TIPPING POINT YOURSELF
  -----------------------------------------------------------------------------
  Each customer has 15 orders. BETWEEN 1 AND k returns 15 x k rows.
  Run each line, and fill in this table on paper:

      k     rows     plan (seek+lookup or scan)    logical reads
      10     150
      100   1500
      200   3000
      300   4500
      400   6000
      600   9000

  EXPECT: small k -> Index Seek + Key Lookup, reads grow ~3 per row.
          At some k the plan flips to a Clustered Index Scan and reads jump to
          a flat ~13,600 no matter how many more rows you ask for.
  The flip often happens when lookups would touch roughly 25-33% as many
  rows as the table has PAGES (13,600 pages -> ~3,400-4,500 rows here),
  i.e. only ~1-1.5% of the ROWS. That surprises most people: an index on a
  column stops being used for seeks+lookups very early.
=============================================================================*/
SELECT * FROM dbo.Orders WHERE CustomerID BETWEEN 1 AND 10;
SELECT * FROM dbo.Orders WHERE CustomerID BETWEEN 1 AND 100;
SELECT * FROM dbo.Orders WHERE CustomerID BETWEEN 1 AND 200;
SELECT * FROM dbo.Orders WHERE CustomerID BETWEEN 1 AND 300;
SELECT * FROM dbo.Orders WHERE CustomerID BETWEEN 1 AND 400;
SELECT * FROM dbo.Orders WHERE CustomerID BETWEEN 1 AND 600;
GO

-- Compare: force the seek at k = 600 and see how much worse it would be.
SELECT * FROM dbo.Orders WITH (INDEX (IX_Orders_CustomerID)) WHERE CustomerID BETWEEN 1 AND 600;
GO

/*=============================================================================
  1.7  A COVERING INDEX REMOVES THE TIPPING POINT
  -----------------------------------------------------------------------------
  INCLUDE adds columns to the index leaf without making them part of the key.
  If the index has everything the query needs, there are no lookups, so the
  seek stays cheap even for many rows.

  EXPECT: Index Seek on IX_Orders_CustomerID_Cover, NO key lookup,
          reads in the tens/low hundreds even for 9,000 rows.
=============================================================================*/
CREATE INDEX IX_Orders_CustomerID_Cover
    ON dbo.Orders (CustomerID) INCLUDE (OrderDate, Amount);
GO
SELECT CustomerID, OrderDate, Amount
FROM dbo.Orders
WHERE CustomerID BETWEEN 1 AND 600;
GO
-- Drop it so later labs behave as written.
DROP INDEX IX_Orders_CustomerID_Cover ON dbo.Orders;
GO

/*=============================================================================
  1.8  ARE THE STATISTICS FRESH?
  -----------------------------------------------------------------------------
  Density and histogram are only as good as the last statistics update.
  modification_counter = rows changed since the last update.
  rows_sampled < rows  = the stats were built from a sample, not a full scan.
=============================================================================*/
SELECT StatName       = s.name,
       sp.last_updated,
       sp.rows,
       sp.rows_sampled,
       sp.steps,                       -- number of histogram steps (max 200)
       sp.modification_counter
FROM sys.stats AS s
CROSS APPLY sys.dm_db_stats_properties(s.object_id, s.stats_id) AS sp
WHERE s.object_id = OBJECT_ID('dbo.Orders')
ORDER BY s.stats_id;
GO

SET STATISTICS IO, TIME OFF;
GO
/*  TAKEAWAYS FROM LAB 01
    - Statistics density = 1 / distinct values. It is about DATA, not storage.
    - High density (few distinct values) -> many rows per value -> scans.
    - Low density (many distinct values) -> few rows per value -> seeks.
    - Key lookups cost ~depth reads PER ROW, which is why the tipping point
      arrives so early. Covering indexes move it.
    - Density is an average; the histogram captures skew. Watch estimates.  */
