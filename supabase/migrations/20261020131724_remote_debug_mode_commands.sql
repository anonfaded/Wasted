-- Remote Debug Mode control: per-device debug_mode_on/debug_mode_off commands.
-- Forward-only migration applied through Supabase MCP after the remote_* migrations.

-- ─── 1. Type allowlists ──────────────────────────────────────────────────────

alter table public.account_actions drop constraint account_actions_type_valid;
alter table public.account_actions
    add constraint account_actions_type_valid
    check (action_type in ('reset_timer', 'force_reset', 'debug_mode_on', 'debug_mode_off'));

alter table public.device_commands drop constraint device_commands_type_valid;
alter table public.device_commands
    add constraint device_commands_type_valid
    check (command_type in ('reset_timer', 'force_reset', 'debug_mode_on', 'debug_mode_off'));

-- ─── 2. Per-device targeting ─────────────────────────────────────────────────

alter table public.account_actions add column device_id uuid null;

alter table public.account_actions
    add constraint account_actions_device_fk foreign key (device_id, account_id)
    references public.devices (id, account_id) on delete cascade;

create index account_actions_device_idx on public.account_actions (device_id, account_id);

alter table public.account_actions
    add constraint account_actions_device_scope_valid
    check ((action_type in ('debug_mode_on', 'debug_mode_off')) = (device_id is not null));

-- ─── 3. Command/action consistency ───────────────────────────────────────────

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

    if action.device_id is not null and new.device_id <> action.device_id then
        raise exception 'device_commands row must match its action device_id';
    end if;

    return new;
end;
$$;

-- ─── 4. Owner RPC ────────────────────────────────────────────────────────────

create function public.set_device_debug_mode(
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
    -- Safety-restoring can wait for an offline device; safety-removing must not go stale.
    ttl := case when p_debug_mode then interval '24 hours' else interval '10 minutes' end;

    -- The device row lock serializes this action against account-wide action fan-out.
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
        if existing.action_type <> action_type or existing.device_id is distinct from p_device_id then
            raise exception 'idempotency key reused for a different action';
        end if;
        return private.action_result_json(existing);
    end if;

    -- Removing the guard must never arm an already queued wipe.
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

    insert into public.account_actions
        (account_id, action_type, idempotency_key, created_by, expires_at, device_id)
    values (uid, action_type, p_idempotency_key, uid, now() + ttl, device.id)
    returning * into action;

    with created_commands as (
        insert into public.device_commands
            (action_id, device_id, account_id, command_type, expires_at)
        values (action.id, device.id, uid, action_type, action.expires_at)
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
            if existing.action_type <> action_type or existing.device_id is distinct from p_device_id then
                raise exception 'idempotency key reused for a different action';
            end if;
            return private.action_result_json(existing);
        end if;
        raise;
end;
$$;

-- ─── 5. Terminal-state whitelist for the new command types ───────────────────

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

-- ─── 6. Execution privileges ─────────────────────────────────────────────────

revoke execute on function public.set_device_debug_mode(uuid, boolean, uuid) from public, anon, authenticated;
grant execute on function public.set_device_debug_mode(uuid, boolean, uuid) to authenticated;
