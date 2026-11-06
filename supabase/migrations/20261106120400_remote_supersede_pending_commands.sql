-- Latest command wins per device. A newly queued command expires older queued/received
-- commands for that device before they can execute. Executing commands are never rewritten.
-- The server trigger is the single enforcement point for account-wide, selected, and debug actions.

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
        returning c.id, c.device_id, c.account_id, c.result_code
    )
    insert into public.command_events (command_id, device_id, account_id, event_type, result_code)
    select id, device_id, account_id, 'expired', result_code from superseded;

    return new;
end;
$$;

drop trigger if exists device_commands_supersede_pending on public.device_commands;
create trigger device_commands_supersede_pending
    before insert on public.device_commands
    for each row execute function private.supersede_pending_device_commands();
