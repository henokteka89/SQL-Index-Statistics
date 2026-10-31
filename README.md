# SQL-Index-Statistics

SQL Server index and statistics scripts and notes, consolidated from separate repositories. Each folder is one former repo, with its full commit history preserved.

## Start here
| Folder | What it covers |
|---|---|
| [statistics_fragmentation_density](statistics_fragmentation_density) | Step-by-step lab: statistics density, seek vs scan, page density and fill factor, fragmentation quadrants, read-ahead I/O, maintenance decision guide |
| [Index-and-Stat](Index-and-Stat) | Index and statistics maintenance notes and document |
| [index-tuning-note](index-tuning-note) | Index tuning notes |

## Indexes
| Folder | What it covers |
|---|---|
| [Index-Average-fragmentation-information](Index-Average-fragmentation-information) | Index fragmentation details |
| [INDEX-SIZE-AND-FILL-FACTOR-](INDEX-SIZE-AND-FILL-FACTOR-) | Index sizes, fill factor, script out rebuilds for low fill factor indexes |
| [Missingindex](Missingindex) | Missing indexes across all databases |
| [Drop-unused-indexes](Drop-unused-indexes) | Check index usage and drop unused indexes |
| [create_drop_index_in_a_table](create_drop_index_in_a_table) | Script out CREATE / DROP for a table's indexes, as a stored procedure |
| [create-drop-index-null-to-notnull](create-drop-index-null-to-notnull) | Drop and recreate indexes to change a column from NULL to NOT NULL |
| [Index-compression](Index-compression) | Index and table compression |
| [filtered-index](filtered-index) | Filtered index example |
| [Change-View-to-Indexed-View](Change-View-to-Indexed-View) | Turn a view into an indexed view with a suggested index |
| [MAX-column-check-if-indexed](MAX-column-check-if-indexed) | Check whether (MAX) columns are part of an index |

## Statistics
| Folder | What it covers |
|---|---|
| [find-outdates-stats](find-outdates-stats) | Find outdated statistics |
| [outdatedstatistics](outdatedstatistics) | Find outdated statistics (earlier version) |
| [Stat](Stat) | Update statistics |
| [OlaHallengren_Update-Stat-For-Actively-Modified-Table](OlaHallengren_Update-Stat-For-Actively-Modified-Table) | Use Ola Hallengren's IndexOptimize to update stats on actively modified tables |
