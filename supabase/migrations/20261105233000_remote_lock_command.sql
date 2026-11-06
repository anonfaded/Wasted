-- Immediate lock-screen command. It is queued like other commands, but expires
-- quickly so an offline device cannot lock itself unexpectedly much later.

alter table public.account_actions
    drop constraint account_actions_type_valid;

alter table public.account_actions
    add constraint account_actions_type_valid
    check (action_type in ('reset_timer', 'force_reset', 'debug_mode_on', 'debug_mode_off', 'lock_now'));

alter table public.device_commands
    drop constraint device_commands_type_valid;

alter table public.device_commands
    add constraint device_commands_type_valid
    check (command_type in ('reset_timer', 'force_reset', 'debug_mode_on', 'debug_mode_off', 'lock_now'));

create or replace function public.create_account_action(
    p_action_type text,
    p_idempotency_key uuid
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
    uid uuid := private.require_owner();
    ttl interval;
    existing public.account_actions;
    action public.account_actions;
    device_count integer;
begin
    if p_action_type is null or p_action_type not in ('reset_timer', 'force_reset', 'lock_now') then
        raise exception 'unsupported action type';
    end if;
    if p_idempotency_key is null then
        raise exception 'idempotency key is required';
    end if;

    ttl := case p_action_type
                when 'reset_timer' then interval '24 hours'
                when 'lock_now' then interval '5 minutes'
                else interval '10 minutes'
           end;

    select * into existing
      from public.account_actions a
     where a.account_id = uid
       and a.idempotency_key = p_idempotency_key;
    if existing.id is not null then
        return private.action_result_json(existing);
    end if;

    insert into public.account_actions
        (account_id, action_type, idempotency_key, created_by, expires_at)
    values (uid, p_action_type, p_idempotency_key, uid, now() + ttl)
    returning * into action;

    -- deterministic device ordering prevents deadlocks between concurrent actions
    with targets as (
        select d.id
          from public.devices d
         where d.account_id = uid
           and d.revoked_at is null
         order by d.id
         for update
    ), created_commands as (
        insert into public.device_commands
            (action_id, device_id, account_id, command_type, expires_at)
        select action.id, t.id, uid, p_action_type, action.expires_at
          from targets t
        returning id, device_id, account_id
    )
    insert into public.command_events (command_id, device_id, account_id, event_type)
    select id, device_id, account_id, 'queued' from created_commands;

    select count(*) into device_count
      from public.device_commands c
     where c.action_id = action.id;

    return jsonb_build_object(
        'action_id', action.id,
        'created_at', action.created_at,
        'expires_at', action.expires_at,
        'device_count', device_count
    );
exception
    when unique_violation then
        select * into existing
          from public.account_actions a
         where a.account_id = uid
           and a.idempotency_key = p_idempotency_key;
        if existing.id is not null then
            return private.action_result_json(existing);
        end if;
        raise;
end;
$$;
