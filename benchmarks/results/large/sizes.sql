-- Storage and B-tree depth of the practo schema. Used for benchmarks/results/large/sizes.txt:
--   psql -X -d <database> -f benchmarks/results/large/sizes.sql
-- Needs the pageinspect extension (PostgreSQL contrib) for the B-tree depth.
SET search_path TO practo;
\pset footer off
\echo 'Tables and summary tables: exact row count, table size (heap + TOAST), size of all its indexes'
SELECT c.relname AS "table",
       CASE c.relkind WHEN 'm' THEN 'materialized view' ELSE 'table' END AS kind,
       (xpath('/row/n/text()', query_to_xml(format('SELECT count(*) AS n FROM practo.%I', c.relname), false, true, '')))[1]::text::bigint AS "rows",
       pg_table_size(c.oid) AS table_bytes,
       pg_size_pretty(pg_table_size(c.oid)) AS table_size,
       pg_indexes_size(c.oid) AS index_bytes,
       pg_size_pretty(pg_indexes_size(c.oid)) AS index_size
FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
WHERE n.nspname = 'practo' AND c.relkind IN ('r', 'm')
ORDER BY pg_total_relation_size(c.oid) DESC, c.relname;

\echo 'Totals'
SELECT sum(pg_table_size(c.oid)) FILTER (WHERE c.relkind = 'r') AS tables_bytes,
       pg_size_pretty(sum(pg_table_size(c.oid)) FILTER (WHERE c.relkind = 'r')) AS tables,
       sum(pg_indexes_size(c.oid)) FILTER (WHERE c.relkind = 'r') AS indexes_on_tables_bytes,
       pg_size_pretty(sum(pg_indexes_size(c.oid)) FILTER (WHERE c.relkind = 'r')) AS indexes_on_tables,
       sum(pg_total_relation_size(c.oid)) FILTER (WHERE c.relkind = 'm') AS summary_tables_bytes,
       pg_size_pretty(sum(pg_total_relation_size(c.oid)) FILTER (WHERE c.relkind = 'm')) AS summary_tables_with_indexes,
       pg_database_size(current_database()) AS database_bytes,
       pg_size_pretty(pg_database_size(current_database())) AS database
FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
WHERE n.nspname = 'practo' AND c.relkind IN ('r', 'm');

\echo 'Phase 4 objects (sql/05_indexes.sql): the 7 indexes, the 2 summary tables and their unique indexes (main relation sizes, as in optimized/index_sizes.txt)'
SELECT c.relname AS object,
       CASE c.relkind WHEN 'i' THEN 'index' WHEN 'm' THEN 'materialized view' END AS kind,
       coalesce(t.relname, '') AS on_table,
       pg_relation_size(c.oid) AS bytes,
       pg_size_pretty(pg_relation_size(c.oid)) AS size,
       CASE WHEN t.oid IS NOT NULL THEN round(100.0 * pg_relation_size(c.oid) / pg_relation_size(t.oid), 1) END AS pct_of_table
FROM pg_class c
JOIN pg_namespace n ON n.oid = c.relnamespace
LEFT JOIN pg_index i ON i.indexrelid = c.oid
LEFT JOIN pg_class t ON t.oid = i.indrelid
WHERE n.nspname = 'practo'
  AND (c.relkind = 'm' OR (c.relkind = 'i' AND (c.relname LIKE 'ix\_%' OR c.relname LIKE 'ux\_%')))
ORDER BY coalesce(t.relname, c.relname), c.relkind DESC, c.relname;

SELECT pg_size_pretty(sum(pg_relation_size(c.oid))) AS phase4_objects_total,
       pg_size_pretty(sum(pg_relation_size(c.oid)) FILTER (WHERE c.relkind = 'i' AND c.relname LIKE 'ix\_%')) AS the_7_indexes,
       pg_size_pretty(sum(pg_relation_size(c.oid)) FILTER (WHERE c.relkind = 'm' OR c.relname LIKE 'ux\_%')) AS the_2_summary_tables_with_their_indexes
FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
WHERE n.nspname = 'practo'
  AND (c.relkind = 'm' OR (c.relkind = 'i' AND (c.relname LIKE 'ix\_%' OR c.relname LIKE 'ux\_%')));

\echo 'B-tree depth: levels from the root page to the leaf pages (pageinspect, bt_metap), every B-tree index'
SET client_min_messages = warning;
CREATE EXTENSION IF NOT EXISTS pageinspect SCHEMA public;
SELECT t.relname AS on_table, c.relname AS index, (public.bt_metap('practo.' || quote_ident(c.relname))).level + 1 AS levels
FROM pg_class c
JOIN pg_namespace n ON n.oid = c.relnamespace
JOIN pg_am am ON am.oid = c.relam AND am.amname = 'btree'
JOIN pg_index i ON i.indexrelid = c.oid
JOIN pg_class t ON t.oid = i.indrelid
WHERE n.nspname = 'practo' AND c.relkind = 'i'
ORDER BY t.relname, c.relname;
