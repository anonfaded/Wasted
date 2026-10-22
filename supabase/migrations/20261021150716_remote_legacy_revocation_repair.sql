-- Terminalize commands left in `executing` by the pre-hardening revoke function. The outcome is
-- unknown, so they are failed, never retried. Idempotent: safe to call repeatedly.
-- Forward-only migration.

create or replace function private.repair_legacy_revoked_commands()
returns integer
language plpgsql
security definer
set search_path = ''
as $$
declare
    repaired integer;
begin
    with stranded as (
        update public.device_commands c
           set state = 'failed',
               finished_at = now(),
               result_code = 'device_revoked_during_execution'
          from public.devices d
         where c.device_id = d.id
           and d.revoked_at is not null
           and c.state = 'executing'
        returning c.id, c.device_id, c.account_id, c.result_code
    ), recorded as (
        insert into public.command_events (command_id, device_id, account_id, event_type, result_code)
        select id, device_id, account_id, 'failed', result_code from stranded
        on conflict (command_id, event_type) do nothing
        returning 1
    )
    select count(*) into repaired from stranded;

    return repaired;
end;
$$;

revoke all on function private.repair_legacy_revoked_commands() from public, anon, authenticated;

select private.repair_legacy_revoked_commands();
