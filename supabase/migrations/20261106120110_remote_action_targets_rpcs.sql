-- Explicit command targets and the shared action creator.
-- The action, target rows, commands, and queued events are one transaction.

create or replace function private.action_result_json(p_action public.account_actions)
returns jsonb
language sql
stable
set search_path = ''
as $$
    select jsonb_build_object(
        'action_id', p_action.id,
        'target_scope', p_action.target_scope,
        'created_at', p_action.created_at,
        'expires_at', p_action.expires_at,
        'device_count', (
            select count(*) from public.device_commands c where c.action_id = p_action.id
        )
    )
$$;

create function private.action_targets_match(p_action_id uuid, p_device_ids uuid[])
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
    with requested as (
        select distinct x as device_id from unnest(p_device_ids) x
    ), actual as (
        select t.device_id
          from public.account_action_targets t
         where t.action_id = p_action_id
    )
    select (select count(*) from requested) = (select count(*) from actual)
       and not exists (
           select 1
             from requested r
            where not exists (
                select 1 from actual a where a.device_id = r.device_id
            )
       );
$$;

create or replace function private.enforce_command_action_consistency()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
    action public.account_actions;
begin
    select * into action from public.account_actions a where a.id = new.action_id;

    if action.id is null then
        raise exception 'device_commands.action_id % does not reference an existing action', new.action_id;
    end if;

    if new.account_id <> action.account_id
        or new.command_type <> action.action_type
        or new.expires_at <> action.expires_at then
        raise exception 'device_commands row must match its action account_id, command_type, and expires_at';
    end if;

    if not exists (
        select 1
          from public.account_action_targets t
         where t.action_id = new.action_id
           and t.account_id = new.account_id
           and t.device_id = new.device_id
    ) then
        raise exception 'device_commands row must match an action target';
    end if;

    return new;
end;
$$;

drop function if exists public.create_account_action(text, uuid);

create function public.create_account_action(
    p_action_type text,
    p_idempotency_key uuid,
    p_target_scope text,
    p_device_ids uuid[]
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
    target_ids uuid[];
    device_count integer;
begin
    if p_action_type is null or p_action_type not in ('reset_timer', 'force_reset', 'lock_now') then
        raise exception 'unsupported action type';
    end if;
    if p_idempotency_key is null then
        raise exception 'idempotency key is required';
    end if;
    if p_target_scope is null or p_target_scope not in ('all', 'selected') then
        raise exception 'target scope must be all or selected';
    end if;
    if p_device_ids is null then
        raise exception 'device ids are required';
    end if;
    if p_target_scope = 'all' and cardinality(p_device_ids) <> 0 then
        raise exception 'device ids must be empty when targeting all devices';
    end if;
    if p_target_scope = 'selected' and cardinality(p_device_ids) = 0 then
        raise exception 'selected targets must not be empty';
    end if;
    if exists (select 1 from unnest(p_device_ids) x where x is null) then
        raise exception 'device ids must not contain null';
    end if;
    if p_target_scope = 'selected'
        and cardinality(p_device_ids) <>
            (select count(*) from (select distinct x from unnest(p_device_ids) x) d) then
        raise exception 'device ids must be unique';
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
        if existing.action_type <> p_action_type
            or existing.target_scope <> p_target_scope then
            raise exception 'idempotency key reused for a different action';
        end if;
        if p_target_scope = 'selected'
            and not private.action_targets_match(existing.id, p_device_ids) then
            raise exception 'idempotency key reused for a different target set';
        end if;
        return private.action_result_json(existing);
    end if;

    if p_target_scope = 'selected' then
        with locked as (
            select d.id
              from public.devices d
             where d.id = any(p_device_ids)
               and d.account_id = uid
               and d.revoked_at is null
             order by d.id
             for update
        )
        select array_agg(l.id order by l.id) into target_ids from locked l;

        if target_ids is null or cardinality(target_ids) <> cardinality(p_device_ids) then
            raise exception 'target device not found or revoked';
        end if;
    else
        with locked as (
            select d.id
              from public.devices d
             where d.account_id = uid
               and d.revoked_at is null
             order by d.id
             for update
        )
        select array_agg(l.id order by l.id) into target_ids from locked l;

        if target_ids is null then
            raise exception 'no active target devices';
        end if;
    end if;

    insert into public.account_actions (
        account_id, action_type, idempotency_key, target_scope, created_by, expires_at
    ) values (
        uid, p_action_type, p_idempotency_key, p_target_scope, uid, now() + ttl
    )
    returning * into action;

    insert into public.account_action_targets (action_id, account_id, device_id)
    select action.id, uid, t.id
      from unnest(target_ids) t(id);

    with created_commands as (
        insert into public.device_commands (
            action_id, device_id, account_id, command_type, expires_at
        )
        select action.id, t.id, uid, p_action_type, action.expires_at
          from unnest(target_ids) t(id)
        returning id, device_id, account_id
    )
    insert into public.command_events (command_id, device_id, account_id, event_type)
    select id, device_id, account_id, 'queued' from created_commands;

    select count(*) into device_count
      from public.device_commands c
     where c.action_id = action.id;

    return jsonb_build_object(
        'action_id', action.id,
        'target_scope', action.target_scope,
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
            if existing.action_type <> p_action_type
                or existing.target_scope <> p_target_scope then
                raise exception 'idempotency key reused for a different action';
            end if;
            if p_target_scope = 'selected'
                and not private.action_targets_match(existing.id, p_device_ids) then
                raise exception 'idempotency key reused for a different target set';
            end if;
            return private.action_result_json(existing);
        end if;
        raise;
end;
$$;

-- Keep the debug switch a single-device owner action, but represent it with the
-- same explicit target model as every other command.
create or replace function public.set_device_debug_mode(
    p_device_id uuid,
    p_debug_mode boolean,
    p_idempotency_key uuid
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
    uid uuid := private.require_owner();
    action_type text;
    ttl interval;
    existing public.account_actions;
    action public.account_actions;
    device public.devices;
begin
    if p_device_id is null then
        raise exception 'device id is required';
    end if;
    if p_debug_mode is null then
        raise exception 'debug mode flag is required';
    end if;
    if p_idempotency_key is null then
        raise exception 'idempotency key is required';
    end if;

    action_type := case when p_debug_mode then 'debug_mode_on' else 'debug_mode_off' end;
    ttl := case when p_debug_mode then interval '24 hours' else interval '10 minutes' end;

    select * into device
      from public.devices d
     where d.id = p_device_id
       and d.account_id = uid
       and d.revoked_at is null
     for update;
    if device.id is null then
        raise exception 'device not found';
    end if;

    select * into existing
      from public.account_actions a
     where a.account_id = uid
       and a.idempotency_key = p_idempotency_key;
    if existing.id is not null then
        if existing.action_type <> action_type
            or existing.target_scope <> 'selected'
            or not private.action_targets_match(existing.id, array[device.id]) then
            raise exception 'idempotency key reused for a different action';
        end if;
        return private.action_result_json(existing);
    end if;

    if action_type = 'debug_mode_off' then
        with superseded as (
            update public.device_commands c
               set state = 'expired',
                   finished_at = now(),
                   result_code = 'superseded_by_debug_off'
             where c.device_id = device.id
               and c.command_type = 'force_reset'
               and c.state in ('queued', 'received')
            returning c.id, c.device_id, c.account_id, c.result_code
        )
        insert into public.command_events (command_id, device_id, account_id, event_type, result_code)
        select id, device_id, account_id, 'expired', result_code from superseded;
    end if;

    insert into public.account_actions (
        account_id, action_type, idempotency_key, target_scope, created_by, expires_at
    ) values (
        uid, action_type, p_idempotency_key, 'selected', uid, now() + ttl
    )
    returning * into action;

    insert into public.account_action_targets (action_id, account_id, device_id)
    values (action.id, uid, device.id);

    with created_commands as (
        insert into public.device_commands (
            action_id, device_id, account_id, command_type, expires_at
        ) values (
            action.id, device.id, uid, action_type, action.expires_at
        )
        returning id, device_id, account_id
    )
    insert into public.command_events (command_id, device_id, account_id, event_type)
    select id, device_id, account_id, 'queued' from created_commands;

    return private.action_result_json(action);
exception
    when unique_violation then
        select * into existing
          from public.account_actions a
         where a.account_id = uid
           and a.idempotency_key = p_idempotency_key;
        if existing.id is not null then
            if existing.action_type <> action_type
                or existing.target_scope <> 'selected'
                or not private.action_targets_match(existing.id, array[device.id]) then
                raise exception 'idempotency key reused for a different action';
            end if;
            return private.action_result_json(existing);
        end if;
        raise;
end;
$$;

-- ─── Command state transitions ──────────────────────────────────────────────

create or replace function public.device_transition_command(
    p_device_id uuid,
    p_command_id uuid,
    p_expected_state text,
    p_new_state text,
    p_result_code text default null,
    p_detail text default null
)
returns public.device_commands
language plpgsql
security definer
set search_path = ''
as $$
declare
    device public.devices;
    command public.device_commands;
    legal boolean;
begin
    device := private.require_active_device(p_device_id);

    if p_result_code is not null and char_length(p_result_code) > 64 then
        raise exception 'result code is too long';
    end if;
    if p_detail is not null and char_length(p_detail) > 256 then
        raise exception 'detail is too long';
    end if;

    select * into command
      from public.device_commands c
     where c.id = p_command_id
       and c.device_id = device.id
     for update;
    if command.id is null then
        raise exception 'command not found for this device';
    end if;

    if command.state <> p_expected_state then
        raise exception 'command state conflict: expected %, found %',
            p_expected_state, command.state;
    end if;

    legal := (command.state, p_new_state) in (
        ('queued', 'received'), ('queued', 'expired'),
        ('received', 'executing'), ('received', 'debug_blocked'),
        ('received', 'rejected'), ('received', 'failed'), ('received', 'expired'),
        ('executing', 'applied'), ('executing', 'reset_initiated'),
        ('executing', 'debug_blocked'), ('executing', 'failed')
    );
    if not legal then
        raise exception 'illegal transition % -> %', command.state, p_new_state;
    end if;

    if p_new_state in ('applied', 'reset_initiated', 'debug_blocked', 'rejected', 'failed', 'expired') then
        if command.command_type = 'reset_timer'
            and p_new_state not in ('applied', 'rejected', 'failed', 'expired') then
            raise exception 'illegal terminal state % for reset_timer', p_new_state;
        end if;
        if command.command_type = 'force_reset'
            and p_new_state not in ('reset_initiated', 'debug_blocked', 'rejected', 'failed', 'expired') then
            raise exception 'illegal terminal state % for force_reset', p_new_state;
        end if;
        if command.command_type = 'lock_now'
            and p_new_state not in ('applied', 'rejected', 'failed', 'expired') then
            raise exception 'illegal terminal state % for lock_now', p_new_state;
        end if;
        if command.command_type in ('debug_mode_on', 'debug_mode_off')
            and p_new_state not in ('applied', 'rejected', 'failed', 'expired') then
            raise exception 'illegal terminal state % for %', p_new_state, command.command_type;
        end if;
    end if;

    if p_new_state in ('received', 'executing') and command.expires_at <= now() then
        raise exception 'command has expired';
    end if;

    update public.device_commands c
       set state = p_new_state,
           received_at = case when p_new_state = 'received' then now() else c.received_at end,
           executing_at = case when p_new_state = 'executing' then now() else c.executing_at end,
           finished_at = case
               when p_new_state in ('applied', 'reset_initiated', 'debug_blocked',
                                    'rejected', 'failed', 'expired')
               then now()
               else c.finished_at
           end,
           result_code = coalesce(p_result_code, c.result_code)
     where c.id = command.id
    returning * into command;

    insert into public.command_events (command_id, device_id, account_id, event_type, result_code, detail)
    values (command.id, command.device_id, command.account_id, p_new_state, p_result_code, p_detail);

    return command;
end;
$$;

revoke execute on function public.create_account_action(text, uuid, text, uuid[])
    from public, anon, authenticated;
grant execute on function public.create_account_action(text, uuid, text, uuid[])
    to authenticated;

revoke execute on function public.set_device_debug_mode(uuid, boolean, uuid)
    from public, anon, authenticated;
grant execute on function public.set_device_debug_mode(uuid, boolean, uuid)
    to authenticated;
