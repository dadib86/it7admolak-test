-- Backup: copies every table into a new dated area (backup_YYYYMMDD_HHMI) that the app cannot reach.
-- Run this in Supabase > SQL Editor BEFORE every update. It says Success when done.
do $$
declare s text := 'backup_' || to_char(now() at time zone 'Africa/Cairo', 'YYYYMMDD_HH24MI'); t record;
begin
  execute format('create schema %I', s);
  for t in select tablename from pg_tables where schemaname = 'public' loop
    execute format('create table %I.%I as table public.%I', s, t.tablename, t.tablename);
  end loop;
end $$;
