-- Free-plan guardrails: bounded command history, stale enrollment cleanup, and one
-- latest-command row per device for the dashboard instead of refetching command history.

create or replace function public.list_latest_device_commands()
returns table (
    id uuid,
    device_id uuid,
    command_type text,
    state text,
    result_code text,
    created_at timestamptz
)
language sql
security invoker
set search_path = ''
as $$
    select distinct on (c.device_id)
           c.id, c.device_id, c.command_type, c.state, c.result_code, c.created_at
      from public.device_commands c
     order by c.device_id, c.created_at desc, c.id desc;
$$;

revoke all on function public.list_latest_device_commands() from public, anon;
grant execute on function public.list_latest_device_commands() to authenticated;

create or replace function private.cleanup_remote_history()
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
    removed_actions bigint := 0;
    batch_count bigint;
    removed_enrollments bigint := 0;
begin
    -- account_actions cascade to device_commands and command_events.
    -- Batch the first run so a long-neglected project cannot hold one large lock.
    for _ in 1..20 loop
        delete from public.account_actions a
         where a.id in (
             select old.id
               from public.account_actions old
              where old.expires_at < now() - interval '180 days'
              order by old.expires_at
              limit 5000
         );
        get diagnostics batch_count = row_count;
        removed_actions := removed_actions + batch_count;
        exit when batch_count = 0;
    end loop;

    delete from private.device_enrollments e
     where e.created_at < now() - interval '30 days'
       and (e.expires_at < now() or e.consumed_at is not null or e.revoked_at is not null);
    get diagnostics removed_enrollments = row_count;

    raise log 'remote cleanup removed % actions and % enrollments',
        removed_actions, removed_enrollments;
end;
$$;

revoke all on function private.cleanup_remote_history() from public, anon, authenticated;

create extension if not exists pg_cron;

do $$
begin
    if exists (select 1 from cron.job where jobname = 'wasted-cleanup-remote-history') then
        perform cron.unschedule('wasted-cleanup-remote-history');
    end if;
end $$;

select cron.schedule(
    'wasted-cleanup-remote-history',
    '45 3 * * *',
    $job$select private.cleanup_remote_history();$job$
);
