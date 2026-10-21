-- Read-only verification for a Wasted Remote database.
-- Run in the Supabase SQL Editor after setup.sql. Every row should say PASS.
with checks as (
    select 'public tables' as check_name, count(*) as found, 7 as expected
      from information_schema.tables
     where table_schema = 'public'
       and table_name in ('accounts', 'devices', 'account_settings', 'device_status',
                          'account_actions', 'device_commands', 'command_events')
    union all
    select 'RLS enabled tables', count(*), 7
      from pg_class c
      join pg_namespace n on n.oid = c.relnamespace
     where n.nspname = 'public'
       and c.relrowsecurity
       and c.relname in ('accounts', 'devices', 'account_settings', 'device_status',
                         'account_actions', 'device_commands', 'command_events')
    union all
    select 'RPC: set_device_debug_mode', count(*), 1
      from pg_proc p
      join pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'public' and p.proname = 'set_device_debug_mode'
    union all
    select 'RPC: device_reconcile', count(*), 1
      from pg_proc p
      join pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'public' and p.proname = 'device_reconcile'
    union all
    select 'Realtime tables', count(*), 4
      from pg_publication_tables
     where pubname = 'supabase_realtime'
       and schemaname = 'public'
       and tablename in ('account_settings', 'devices', 'device_status', 'device_commands')
    union all
    select 'anonymous cleanup job', count(*), 1
      from cron.job
     where jobname = 'wasted-cleanup-anonymous-identities'
)
select check_name, found, expected,
       case when found = expected then 'PASS' else 'FAIL' end as result
  from checks
 order by check_name;
