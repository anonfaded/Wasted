-- Remote management RPCs. Every function is security definer with an empty search_path,
-- fully schema-qualifies objects, validates inputs, and is executable only by `authenticated`
-- (anonymous device sessions assume that role and are distinguished by the JWT is_anonymous claim).
-- Forward-only migration.

-- ─── Private helpers ─────────────────────────────────────────────────────────

create function private.is_anonymous_user()
returns boolean
language sql
stable
set search_path = ''
as $$
    select coalesce((auth.jwt() ->> 'is_anonymous')::boolean, false)
$$;

create function private.require_owner()
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
    uid uuid := (select auth.uid());
begin
    if uid is null then
        raise exception 'authentication required';
    end if;
    if private.is_anonymous_user() then
        raise exception 'owner account required';
    end if;
    if not exists (select 1 from public.accounts a where a.id = uid) then
        raise exception 'owner account not initialized';
    end if;
    return uid;
end;
$$;

create function private.require_active_device(p_device_id uuid)
returns public.devices
language plpgsql
security definer
set search_path = ''
as $$
declare
    uid uuid := (select auth.uid());
    device public.devices;
begin
    if uid is null then
        raise exception 'authentication required';
    end if;
    select * into device
      from public.devices d
     where d.id = p_device_id
       and d.auth_user_id = uid
       and d.revoked_at is null;
    if device.id is null then
        raise exception 'active device not found for this identity';
    end if;
    return device;
end;
$$;

-- ─── Owner RPCs ──────────────────────────────────────────────────────────────

create function public.initialize_owner_account(p_handle text)
returns public.accounts
language plpgsql
security definer
set search_path = ''
as $$
declare
    uid uuid := (select auth.uid());
    trimmed text := btrim(p_handle);
    account public.accounts;
begin
    if uid is null then
        raise exception 'authentication required';
    end if;
    if private.is_anonymous_user() then
        raise exception 'owner account required';
    end if;

    select * into account from public.accounts a where a.id = uid;
    if account.id is not null then
        return account;
    end if;

    if trimmed is null
        or char_length(trimmed) < 3
        or char_length(trimmed) > 32
        or trimmed !~ '^[A-Za-z0-9][A-Za-z0-9_.-]{2,31}$' then
        raise exception 'handle must be 3-32 characters: letters, digits, dot, dash, underscore';
    end if;

    insert into public.accounts (id, handle) values (uid, trimmed)
    returning * into account;
    insert into public.account_settings (account_id) values (uid);

    return account;
exception
    when unique_violation then
        select * into account from public.accounts a where a.id = uid;
        if account.id is not null then
            return account;
        end if;
        raise exception 'handle is already taken';
end;
$$;

create function public.create_device_enrollment()
returns table (enrollment_id uuid, enrollment_token text, expires_at timestamptz)
language plpgsql
security definer
set search_path = ''
as $$
declare
    uid uuid := private.require_owner();
    token text;
    enrollment private.device_enrollments;
begin
    token := encode(extensions.gen_random_bytes(32), 'hex');

    update private.device_enrollments e
       set revoked_at = now()
     where e.account_id = uid
       and e.consumed_at is null
       and e.revoked_at is null;

    insert into private.device_enrollments (account_id, token_hash, expires_at)
    values (uid, extensions.digest(token, 'sha256'), now() + interval '10 minutes')
    returning * into enrollment;

    return query select enrollment.id, token, enrollment.expires_at;
end;
$$;

create function public.rename_device(p_device_id uuid, p_name text)
returns public.devices
language plpgsql
security definer
set search_path = ''
as $$
declare
    uid uuid := private.require_owner();
    trimmed text := btrim(p_name);
    device public.devices;
begin
    if trimmed is null or char_length(trimmed) < 1 or char_length(trimmed) > 80 then
        raise exception 'device name must be 1-80 characters';
    end if;

    update public.devices d
       set name = trimmed, updated_at = now()
     where d.id = p_device_id
       and d.account_id = uid
       and d.revoked_at is null
    returning * into device;

    if device.id is null then
        raise exception 'device not found';
    end if;
    return device;
end;
$$;

create function public.revoke_device(p_device_id uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
    uid uuid := private.require_owner();
    device public.devices;
begin
    select * into device
      from public.devices d
     where d.id = p_device_id
       and d.account_id = uid
     for update;
    if device.id is null then
        raise exception 'device not found';
    end if;
    if device.revoked_at is not null then
        return;
    end if;

    update public.devices d
       set revoked_at = now(), updated_at = now()
     where d.id = p_device_id;

    -- reject only queued/received commands; executing/terminal rows are preserved as-is
    with rejected as (
        update public.device_commands c
           set state = 'rejected',
               finished_at = now(),
               result_code = 'device_revoked'
         where c.device_id = p_device_id
           and c.state in ('queued', 'received')
        returning c.id, c.device_id, c.account_id, c.result_code
    )
    insert into public.command_events (command_id, device_id, account_id, event_type, result_code)
    select id, device_id, account_id, 'rejected', result_code from rejected;
end;
$$;

create function public.update_account_settings(
    p_expected_revision bigint,
    p_lock_timer_minutes integer,
    p_usb_trigger_enabled boolean
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
    if p_lock_timer_minutes is null
        or p_lock_timer_minutes < 1
        or p_lock_timer_minutes > 525600 then
        raise exception 'lock timer minutes must be between 1 and 525600';
    end if;
    if p_usb_trigger_enabled is null then
        raise exception 'usb trigger flag is required';
    end if;

    update public.account_settings s
       set lock_timer_minutes = p_lock_timer_minutes,
           usb_trigger_enabled = p_usb_trigger_enabled,
           revision = s.revision + 1,
           initialized_at = coalesce(s.initialized_at, now()),
           updated_by = uid,
           updated_at = now()
     where s.account_id = uid
       and s.revision = p_expected_revision
    returning * into settings;

    if settings.account_id is null then
        raise exception 'settings revision conflict';
    end if;
    return settings;
end;
$$;

create function public.create_account_action(
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
    if p_action_type is null or p_action_type not in ('reset_timer', 'force_reset') then
        raise exception 'unsupported action type';
    end if;
    if p_idempotency_key is null then
        raise exception 'idempotency key is required';
    end if;

    ttl := case when p_action_type = 'reset_timer'
                then interval '24 hours'
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

create function private.action_result_json(p_action public.account_actions)
returns jsonb
language sql
stable
set search_path = ''
as $$
    select jsonb_build_object(
        'action_id', p_action.id,
        'created_at', p_action.created_at,
        'expires_at', p_action.expires_at,
        'device_count', (
            select count(*) from public.device_commands c where c.action_id = p_action.id
        )
    )
$$;

create function public.expire_account_commands()
returns integer
language plpgsql
security definer
set search_path = ''
as $$
declare
    uid uuid := private.require_owner();
    expired_count integer;
begin
    with expired as (
        update public.device_commands c
           set state = 'expired',
               finished_at = now(),
               result_code = 'expired'
         where c.account_id = uid
           and c.state in ('queued', 'received')
           and c.expires_at <= now()
        returning c.id, c.device_id, c.account_id, c.result_code
    )
    insert into public.command_events (command_id, device_id, account_id, event_type, result_code)
    select id, device_id, account_id, 'expired', result_code from expired;

    get diagnostics expired_count = row_count;
    return expired_count;
end;
$$;

-- ─── Device RPCs ─────────────────────────────────────────────────────────────

create function public.claim_device_enrollment(
    p_token text,
    p_installation_id uuid,
    p_device_name text,
    p_local_lock_timer_minutes integer,
    p_local_usb_trigger_enabled boolean
)
returns public.devices
language plpgsql
security definer
set search_path = ''
as $$
declare
    uid uuid := (select auth.uid());
    trimmed_name text := btrim(p_device_name);
    enrollment private.device_enrollments;
    existing_device public.devices;
    settings_row public.account_settings;
    device public.devices;
begin
    if uid is null then
        raise exception 'authentication required';
    end if;
    if not private.is_anonymous_user() then
        raise exception 'device enrollment requires an anonymous device identity';
    end if;
    if p_token is null or p_token !~ '^[0-9a-f]{64}$' then
        raise exception 'enrollment token must be 64 lowercase hex characters';
    end if;
    if p_installation_id is null then
        raise exception 'installation id is required';
    end if;
    if trimmed_name is null or char_length(trimmed_name) < 1 or char_length(trimmed_name) > 80 then
        raise exception 'device name must be 1-80 characters';
    end if;
    if p_local_lock_timer_minutes is null
        or p_local_lock_timer_minutes < 1
        or p_local_lock_timer_minutes > 2147483647 then
        raise exception 'lock timer minutes must be >= 1';
    end if;
    if p_local_usb_trigger_enabled is null then
        raise exception 'usb trigger flag is required';
    end if;

    -- lost-response retry: the same identity + installation id returns the same device
    select * into existing_device
      from public.devices d
     where d.installation_id = p_installation_id;
    if existing_device.id is not null then
        if existing_device.auth_user_id = uid then
            return existing_device;
        end if;
        raise exception 'installation id is already bound to another identity';
    end if;

    select * into enrollment
      from private.device_enrollments e
     where e.token_hash = extensions.digest(p_token, 'sha256')
     for update;
    if enrollment.id is null then
        raise exception 'enrollment token not found';
    end if;
    if enrollment.revoked_at is not null then
        raise exception 'enrollment token was revoked';
    end if;
    if enrollment.consumed_at is not null then
        raise exception 'enrollment token was already used';
    end if;
    if enrollment.expires_at <= now() then
        raise exception 'enrollment token has expired';
    end if;

    -- serialize first-claim settings seeding per account
    select * into settings_row
      from public.account_settings s
     where s.account_id = enrollment.account_id
     for update;

    insert into public.devices (account_id, auth_user_id, installation_id, name)
    values (enrollment.account_id, uid, p_installation_id, trimmed_name)
    returning * into device;

    update private.device_enrollments e
       set consumed_at = now(), consumed_by_device_id = device.id
     where e.id = enrollment.id;

    if settings_row.initialized_at is null then
        update public.account_settings s
           set lock_timer_minutes = p_local_lock_timer_minutes,
               usb_trigger_enabled = p_local_usb_trigger_enabled,
               revision = 1,
               initialized_at = now(),
               updated_by = uid,
               updated_at = now()
         where s.account_id = enrollment.account_id
           and s.initialized_at is null;
    end if;

    return device;
exception
    when unique_violation then
        select * into existing_device
          from public.devices d
         where d.installation_id = p_installation_id;
        if existing_device.id is not null and existing_device.auth_user_id = uid then
            return existing_device;
        end if;
        raise;
end;
$$;

create function public.device_reconcile(
    p_device_id uuid,
    p_applied_settings_revision bigint,
    p_actual_lock_timer_minutes integer,
    p_actual_usb_trigger_enabled boolean,
    p_timer_remaining_seconds bigint,
    p_timer_running boolean,
    p_debug_mode boolean,
    p_reset_supported boolean,
    p_remote_enabled boolean,
    p_app_version text,
    p_android_sdk smallint,
    p_last_error_code text default null,
    p_last_error_message text default null
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
    device public.devices;
    settings_row public.account_settings;
    commands jsonb;
    server_now timestamptz := now();
begin
    device := private.require_active_device(p_device_id);

    if p_applied_settings_revision is null or p_applied_settings_revision < 0 then
        raise exception 'applied settings revision must be >= 0';
    end if;
    if p_actual_lock_timer_minutes is null or p_actual_lock_timer_minutes < 1 then
        raise exception 'actual lock timer minutes must be >= 1';
    end if;
    if p_timer_remaining_seconds is null or p_timer_remaining_seconds < 0 then
        raise exception 'timer remaining seconds must be >= 0';
    end if;
    if p_app_version is null or char_length(p_app_version) < 1 or char_length(p_app_version) > 64 then
        raise exception 'app version must be 1-64 characters';
    end if;
    if p_android_sdk is null or p_android_sdk < 24 or p_android_sdk > 1000 then
        raise exception 'android sdk must be between 24 and 1000';
    end if;
    if p_last_error_code is not null and char_length(p_last_error_code) > 64 then
        raise exception 'last error code is too long';
    end if;
    if p_last_error_message is not null and char_length(p_last_error_message) > 256 then
        raise exception 'last error message is too long';
    end if;

    insert into public.device_status (
        device_id, account_id, applied_settings_revision,
        actual_lock_timer_minutes, actual_usb_trigger_enabled,
        timer_remaining_seconds, timer_running,
        debug_mode, reset_supported, remote_enabled,
        app_version, android_sdk, last_error_code, last_error_message,
        timer_sampled_at, last_seen_at, updated_at
    ) values (
        device.id, device.account_id, p_applied_settings_revision,
        p_actual_lock_timer_minutes, p_actual_usb_trigger_enabled,
        p_timer_remaining_seconds, p_timer_running,
        p_debug_mode, p_reset_supported, p_remote_enabled,
        p_app_version, p_android_sdk, p_last_error_code, p_last_error_message,
        server_now, server_now, server_now
    )
    on conflict (device_id) do update set
        applied_settings_revision = excluded.applied_settings_revision,
        actual_lock_timer_minutes = excluded.actual_lock_timer_minutes,
        actual_usb_trigger_enabled = excluded.actual_usb_trigger_enabled,
        timer_remaining_seconds = excluded.timer_remaining_seconds,
        timer_running = excluded.timer_running,
        debug_mode = excluded.debug_mode,
        reset_supported = excluded.reset_supported,
        remote_enabled = excluded.remote_enabled,
        app_version = excluded.app_version,
        android_sdk = excluded.android_sdk,
        last_error_code = excluded.last_error_code,
        last_error_message = excluded.last_error_message,
        timer_sampled_at = excluded.timer_sampled_at,
        last_seen_at = excluded.last_seen_at,
        updated_at = excluded.updated_at;

    -- lazily expire overdue queued/received commands for this device
    with expired as (
        update public.device_commands c
           set state = 'expired',
               finished_at = server_now,
               result_code = 'expired'
         where c.device_id = device.id
           and c.state in ('queued', 'received')
           and c.expires_at <= server_now
        returning c.id, c.device_id, c.account_id, c.result_code
    )
    insert into public.command_events (command_id, device_id, account_id, event_type, result_code)
    select id, device_id, account_id, 'expired', result_code from expired;

    select * into settings_row
      from public.account_settings s
     where s.account_id = device.account_id;

    select coalesce(
               jsonb_agg(
                   jsonb_build_object(
                       'id', c.id,
                       'action_id', c.action_id,
                       'command_type', c.command_type,
                       'state', c.state,
                       'created_at', c.created_at,
                       'expires_at', c.expires_at
                   ) order by c.created_at
               ),
               '[]'::jsonb
           )
      into commands
      from public.device_commands c
     where c.device_id = device.id
       and c.state in ('queued', 'received')
       and c.expires_at > server_now;

    return jsonb_build_object(
        'server_time', server_now,
        'device', jsonb_build_object(
            'id', device.id,
            'account_id', device.account_id,
            'name', device.name,
            'installation_id', device.installation_id,
            'enrolled_at', device.enrolled_at
        ),
        'settings', jsonb_build_object(
            'revision', settings_row.revision,
            'lock_timer_minutes', settings_row.lock_timer_minutes,
            'usb_trigger_enabled', settings_row.usb_trigger_enabled,
            'initialized', settings_row.initialized_at is not null
        ),
        'commands', commands
    );
end;
$$;

create function public.device_transition_command(
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

-- ─── Execution privileges ────────────────────────────────────────────────────

revoke execute on function public.initialize_owner_account(text) from public, anon, authenticated;
revoke execute on function public.create_device_enrollment() from public, anon, authenticated;
revoke execute on function public.rename_device(uuid, text) from public, anon, authenticated;
revoke execute on function public.revoke_device(uuid) from public, anon, authenticated;
revoke execute on function public.update_account_settings(bigint, integer, boolean) from public, anon, authenticated;
revoke execute on function public.create_account_action(text, uuid) from public, anon, authenticated;
revoke execute on function public.expire_account_commands() from public, anon, authenticated;
revoke execute on function public.claim_device_enrollment(text, uuid, text, integer, boolean) from public, anon, authenticated;
revoke execute on function public.device_reconcile(uuid, bigint, integer, boolean, bigint, boolean, boolean, boolean, boolean, text, smallint, text, text) from public, anon, authenticated;
revoke execute on function public.device_transition_command(uuid, uuid, text, text, text, text) from public, anon, authenticated;

grant execute on function public.initialize_owner_account(text) to authenticated;
grant execute on function public.create_device_enrollment() to authenticated;
grant execute on function public.rename_device(uuid, text) to authenticated;
grant execute on function public.revoke_device(uuid) to authenticated;
grant execute on function public.update_account_settings(bigint, integer, boolean) to authenticated;
grant execute on function public.create_account_action(text, uuid) to authenticated;
grant execute on function public.expire_account_commands() to authenticated;
grant execute on function public.claim_device_enrollment(text, uuid, text, integer, boolean) to authenticated;
grant execute on function public.device_reconcile(uuid, bigint, integer, boolean, bigint, boolean, boolean, boolean, boolean, text, smallint, text, text) to authenticated;
grant execute on function public.device_transition_command(uuid, uuid, text, text, text, text) to authenticated;

revoke execute on function private.is_anonymous_user() from public, anon, authenticated;
revoke execute on function private.require_owner() from public, anon, authenticated;
revoke execute on function private.require_active_device(uuid) from public, anon, authenticated;
revoke execute on function private.action_result_json(public.account_actions) from public, anon, authenticated;
revoke execute on function private.enforce_command_action_consistency() from public, anon, authenticated;
