-- Narrow latest-command semantics to one command family per device.
-- Reset Timer, Lock now, and Force Reset are independent families. Debug ON/OFF
-- share one family because they mutate the same Debug Mode setting.
-- Only queued/received commands are superseded; an executing command cannot be recalled.

create or replace function private.supersede_pending_device_commands()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
    with superseded as (
        update public.device_commands c
           set state = 'expired',
               finished_at = now(),
               result_code = 'superseded_by_new_action'
         where c.device_id = new.device_id
           and c.state in ('queued', 'received')
           and c.id <> new.id
           and (
               c.command_type = new.command_type
               or (
                   c.command_type in ('debug_mode_on', 'debug_mode_off')
                   and new.command_type in ('debug_mode_on', 'debug_mode_off')
               )
           )
        returning c.id, c.device_id, c.account_id, c.result_code
    )
    insert into public.command_events (command_id, device_id, account_id, event_type, result_code)
    select id, device_id, account_id, 'expired', result_code from superseded;

    return new;
end;
$$;
