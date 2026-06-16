-- ============================================================
-- READ-ONLY schema audit. Safe: only counts rows, creates a temp helper
-- function, queries it once, and drops it. Run in the Supabase SQL editor and
-- paste the single result set back.
--
-- Returns ONE table with a `kind` column:
--   EMPTY COLUMN    = column is 100% NULL in a table that HAS rows  -> drop candidate
--   ZERO-ROW TABLE  = table has no rows at all                      -> unused-table candidate
-- A human still decides — some empty columns are intentionally new (e.g. the
-- tournament payment fields) or are written only by triggers/RPCs.
-- ============================================================

create or replace function public._audit_columns()
returns table(tbl text, col text, rows bigint, non_null bigint)
language plpgsql as $$
declare r record; n bigint; nn bigint;
begin
  for r in
    select c.table_name, c.column_name
    from information_schema.columns c
    join information_schema.tables t
      on t.table_schema = c.table_schema and t.table_name = c.table_name
    where c.table_schema = 'public' and t.table_type = 'BASE TABLE'
    order by c.table_name, c.ordinal_position
  loop
    execute format('select count(*), count(%I) from public.%I',
                   r.column_name, r.table_name) into n, nn;
    tbl := r.table_name; col := r.column_name; rows := n; non_null := nn;
    return next;
  end loop;
end $$;

with a as (select * from public._audit_columns())
select 'EMPTY COLUMN'   as kind, tbl, col           as detail, rows
  from a where non_null = 0 and rows > 0
union all
select 'ZERO-ROW TABLE' as kind, tbl, '(whole table)' as detail, 0 as rows
  from (select tbl from a group by tbl having max(rows) = 0) z
order by kind, tbl, detail;

drop function public._audit_columns();
