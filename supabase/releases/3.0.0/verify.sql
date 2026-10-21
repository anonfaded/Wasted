-- Read-only verification for a Wasted Remote database.
-- Run in the Supabase SQL Editor after setup.sql. Every row must say PASS; any FAIL raises.
-- This checks catalog invariants (RLS force, policies, grants, RPC properties, publication,
-- schema marker), not just table names.

drop table if exists pg_temp.verify_results;

create temp table pg_temp.verify_results as
with expected_tables(name) as (
    values ('accounts'), ('devices'), ('account_settings'), ('device_status'),
           ('account_actions'), ('device_commands'), ('command_events')
),
expected_policies(name) as (
    values ('accounts_select_owner'),
           ('devices_select'),
           ('account_settings_select'),
           ('device_status_select_owner'),
           ('account_actions_select_owner'),
           ('device_commands_select'),
           ('command_events_select_owner')
),
expected_rpcs(signature) as (
    values ('public.initialize_owner_account(text)'),
           ('public.create_device_enrollment()'),
           ('public.rename_device(uuid,text)'),
           ('public.revoke_device(uuid)'),
           ('public.update_account_settings(bigint,integer,boolean)'),
           ('public.create_account_action(text,uuid)'),
           ('public.expire_account_commands()'),
           ('public.claim_device_enrollment(text,uuid,text,integer,boolean)'),
           ('public.device_reconcile(uuid,bigint,integer,boolean,bigint,boolean,boolean,boolean,boolean,text,smallint,text,text)'),
           ('public.device_transition_command(uuid,uuid,text,text,text,text)'),
           ('public.set_device_debug_mode(uuid,boolean,uuid)')
),
checks as (
    select 'public tables' as check_name, count(*) as found, 7 as expected
      from expected_tables
     where to_regclass('public.' || name) is not null
    union all
    select 'RLS enabled', count(*), 7
      from pg_class c
      join pg_namespace n on n.oid = c.relnamespace
     where n.nspname = 'public' and c.relname in (select name from expected_tables)
       and c.relrowsecurity
    union all
    select 'RLS forced', count(*), 7
      from pg_class c
      join pg_namespace n on n.oid = c.relnamespace
     where n.nspname = 'public' and c.relname in (select name from expected_tables)
       and c.relrowsecurity and c.relforcerowsecurity
    union all
    select 'SELECT-only policies', count(*), 7
      from pg_policies
     where schemaname = 'public' and tablename in (select name from expected_tables)
       and cmd = 'SELECT' and policyname in (select name from expected_policies)
    union all
    select 'no write policies', count(*), 0
      from pg_policies
     where schemaname = 'public' and tablename in (select name from expected_tables)
       and cmd <> 'SELECT'
    union all
    select 'authenticated select-only grants', count(*), 7
      from expected_tables
     where has_table_privilege('authenticated', format('public.%I', name), 'SELECT')
       and not has_table_privilege('authenticated', format('public.%I', name), 'INSERT')
       and not has_table_privilege('authenticated', format('public.%I', name), 'UPDATE')
       and not has_table_privilege('authenticated', format('public.%I', name), 'DELETE')
    union all
    select 'anon table access', count(*), 0
      from expected_tables
     where has_table_privilege('anon', format('public.%I', name), 'SELECT')
        or has_table_privilege('anon', format('public.%I', name), 'INSERT')
        or has_table_privilege('anon', format('public.%I', name), 'UPDATE')
        or has_table_privilege('anon', format('public.%I', name), 'DELETE')
    union all
    select 'private schema isolation', count(*), 0
      from (values ('anon'), ('authenticated')) roles(role_name)
     where has_schema_privilege(role_name, 'private', 'USAGE')
        or has_table_privilege(role_name, 'private.device_enrollments', 'SELECT')
    union all
    select 'public RPCs present', count(*), 11
      from expected_rpcs
     where to_regprocedure(signature) is not null
    union all
    select 'RPC security definer', count(*), 11
      from expected_rpcs e
      join pg_proc p on p.oid = to_regprocedure(e.signature)
     where p.prosecdef
    union all
    select 'RPC owned by postgres', count(*), 11
      from expected_rpcs e
      join pg_proc p on p.oid = to_regprocedure(e.signature)
     where pg_get_userbyid(p.proowner) = 'postgres'
    union all
    select 'RPC empty search_path', count(*), 11
      from expected_rpcs e
      join pg_proc p on p.oid = to_regprocedure(e.signature)
     where 'search_path=""' = any(p.proconfig)
    union all
    select 'RPC authenticated-only execute', count(*), 11
      from expected_rpcs e
      join pg_proc p on p.oid = to_regprocedure(e.signature)
     where has_function_privilege('authenticated', p.oid, 'EXECUTE')
       and not has_function_privilege('anon', p.oid, 'EXECUTE')
    union all
    select 'Realtime exact tables', count(*), 4
      from pg_publication_tables
     where pubname = 'supabase_realtime' and schemaname = 'public'
       and tablename in ('account_settings', 'devices', 'device_status', 'device_commands')
    union all
    select 'Realtime extra tables', count(*), 0
      from pg_publication_tables
     where pubname = 'supabase_realtime' and schemaname = 'public'
       and tablename not in ('account_settings', 'devices', 'device_status', 'device_commands')
    union all
    select 'anonymous cleanup job', count(*), 1
      from cron.job
     where jobname = 'wasted-cleanup-anonymous-identities'
    union all
    select 'schema version marker', count(*), 1
      from pg_namespace
     where nspname = 'public'
       and obj_description(oid, 'pg_namespace') = 'wasted-remote-schema:1'
    union all
    select 'future functions deny PUBLIC', count(*), 0
      from pg_default_acl d
      cross join lateral aclexplode(d.defaclacl) a
     where d.defaclrole = 'postgres'::regrole
       and d.defaclnamespace in (0, 'public'::regnamespace)
       and d.defaclobjtype = 'f'
       and a.grantee = 0
       and a.privilege_type = 'EXECUTE'
)
select check_name, found, expected,
       case when found = expected then 'PASS' else 'FAIL' end as result
  from checks;

do $$
declare
    failures integer;
begin
    select count(*) into failures
      from pg_temp.verify_results
     where result = 'FAIL';
    if failures > 0 then
        raise exception 'verification failed: % check(s) did not pass', failures;
    end if;
end;
$$;
