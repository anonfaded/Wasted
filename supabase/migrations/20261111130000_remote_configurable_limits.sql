-- Account-configurable command, enrollment, and dashboard status limits.
-- Defaults define the standard behavior; limits_revision is independent of the
-- trigger settings revision so changing a timeout does not reapply device settings.

alter table public.account_settings
    add column limits_revision bigint not null default 0,
    add column enrollment_token_ttl_minutes integer not null default 10,
    add column lock_command_ttl_minutes integer not null default 5,
    add column force_reset_ttl_minutes integer not null default 10,
    add column reset_timer_ttl_minutes integer not null default 1440,
    add column debug_mode_on_ttl_minutes integer not null default 1440,
    add column debug_mode_off_ttl_minutes integer not null default 10;

alter table public.account_settings
    add constraint account_settings_limits_revision_nonnegative
        check (limits_revision >= 0),
    add constraint account_settings_enrollment_ttl_range
        check (enrollment_token_ttl_minutes between 1 and 60),
    add constraint account_settings_lock_command_ttl_range
        check (lock_command_ttl_minutes between 1 and 10080),
    add constraint account_settings_force_reset_ttl_range
        check (force_reset_ttl_minutes between 1 and 10080),
    add constraint account_settings_reset_timer_ttl_range
        check (reset_timer_ttl_minutes between 1 and 10080),
    add constraint account_settings_debug_mode_on_ttl_range
        check (debug_mode_on_ttl_minutes between 1 and 10080),
    add constraint account_settings_debug_mode_off_ttl_range
        check (debug_mode_off_ttl_minutes between 1 and 10080);

create function public.update_account_limits(
    p_expected_revision bigint,
    p_enrollment_token_ttl_minutes integer,
    p_lock_command_ttl_minutes integer,
    p_force_reset_ttl_minutes integer,
    p_reset_timer_ttl_minutes integer,
    p_debug_mode_on_ttl_minutes integer,
    p_debug_mode_off_ttl_minutes integer
)
returns public.account_settings
language plpgsql
security definer
set search_path = ''
as $$
declare
    uid uuid := private.require_owner();
    settings public.account_settings;
begin
    if p_expected_revision is null or p_expected_revision < 0 then
        raise exception 'expected revision must be >= 0';
    end if;
    if p_enrollment_token_ttl_minutes is null
        or p_enrollment_token_ttl_minutes < 1
        or p_enrollment_token_ttl_minutes > 60 then
        raise exception 'enrollment token lifetime must be between 1 and 60 minutes';
    end if;
    if p_lock_command_ttl_minutes is null
        or p_lock_command_ttl_minutes < 1
        or p_lock_command_ttl_minutes > 10080 then
        raise exception 'lock command expiry must be between 1 and 10080 minutes';
    end if;
    if p_force_reset_ttl_minutes is null
        or p_force_reset_ttl_minutes < 1
        or p_force_reset_ttl_minutes > 10080 then
        raise exception 'force reset expiry must be between 1 and 10080 minutes';
    end if;
    if p_reset_timer_ttl_minutes is null
        or p_reset_timer_ttl_minutes < 1
        or p_reset_timer_ttl_minutes > 10080 then
        raise exception 'reset timer expiry must be between 1 and 10080 minutes';
    end if;
    if p_debug_mode_on_ttl_minutes is null
        or p_debug_mode_on_ttl_minutes < 1
        or p_debug_mode_on_ttl_minutes > 10080 then
        raise exception 'debug mode on expiry must be between 1 and 10080 minutes';
    end if;
    if p_debug_mode_off_ttl_minutes is null
        or p_debug_mode_off_ttl_minutes < 1
        or p_debug_mode_off_ttl_minutes > 10080 then
        raise exception 'debug mode off expiry must be between 1 and 10080 minutes';
    end if;
    update public.account_settings s
       set enrollment_token_ttl_minutes = p_enrollment_token_ttl_minutes,
           lock_command_ttl_minutes = p_lock_command_ttl_minutes,
           force_reset_ttl_minutes = p_force_reset_ttl_minutes,
           reset_timer_ttl_minutes = p_reset_timer_ttl_minutes,
           debug_mode_on_ttl_minutes = p_debug_mode_on_ttl_minutes,
           debug_mode_off_ttl_minutes = p_debug_mode_off_ttl_minutes,
           limits_revision = s.limits_revision + 1,
           updated_by = uid,
           updated_at = now()
     where s.account_id = uid
       and s.limits_revision = p_expected_revision
    returning * into settings;

    if settings.account_id is null then
        raise exception 'limits revision conflict';
    end if;
    return settings;
end;
$$;

revoke execute on function public.update_account_limits(
    bigint, integer, integer, integer, integer, integer, integer
) from public, anon, authenticated;
grant execute on function public.update_account_limits(
    bigint, integer, integer, integer, integer, integer, integer
) to authenticated;

create or replace function public.create_device_enrollment()
returns table (enrollment_id uuid, enrollment_token text, expires_at timestamptz)
language plpgsql
security definer
set search_path = ''
as $$
declare
    uid uuid := private.require_owner();
    token text;
    enrollment private.device_enrollments;
    ttl_minutes integer;
begin
    select s.enrollment_token_ttl_minutes
      into ttl_minutes
      from public.account_settings s
     where s.account_id = uid;

    token := encode(extensions.gen_random_bytes(32), 'hex');

    insert into private.device_enrollments (account_id, token_hash, expires_at)
    values (uid, extensions.digest(token, 'sha256'), now() + make_interval(mins => ttl_minutes))
    returning * into enrollment;

    return query select enrollment.id, token, enrollment.expires_at;
end;
$$;

create or replace function public.create_account_action(
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
    ttl_minutes integer;
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

    select case p_action_type
               when 'reset_timer' then s.reset_timer_ttl_minutes
               when 'lock_now' then s.lock_command_ttl_minutes
               else s.force_reset_ttl_minutes
           end
      into ttl_minutes
      from public.account_settings s
     where s.account_id = uid;
    ttl := make_interval(mins => ttl_minutes);

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
    ttl_minutes integer;
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
    select case when p_debug_mode
                    then s.debug_mode_on_ttl_minutes
                    else s.debug_mode_off_ttl_minutes
                end
      into ttl_minutes
      from public.account_settings s
     where s.account_id = uid;
    ttl := make_interval(mins => ttl_minutes);

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
