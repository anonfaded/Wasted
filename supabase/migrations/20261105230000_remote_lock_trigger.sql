-- Make the Lock trigger part of the account-wide remote settings and report its
-- actual state. The delay remains separate: the trigger arms the timer, the delay
-- decides when the armed timer fires.

alter table public.account_settings
    add column lock_trigger_enabled boolean not null default false;

alter table public.device_status
    add column actual_lock_trigger_enabled boolean null;

-- Keep the old five-argument call working for older APKs. The new argument is
-- optional and only seeds the new account setting when it is supplied.
drop function if exists public.claim_device_enrollment(text, uuid, text, integer, boolean);

create function public.claim_device_enrollment(
    p_token text,
    p_installation_id uuid,
    p_device_name text,
    p_local_lock_timer_minutes integer,
    p_local_usb_trigger_enabled boolean,
    p_local_lock_trigger_enabled boolean default null
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
               lock_trigger_enabled = coalesce(p_local_lock_trigger_enabled, false),
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

revoke execute on function public.claim_device_enrollment(text, uuid, text, integer, boolean, boolean)
    from public, anon, authenticated;
grant execute on function public.claim_device_enrollment(text, uuid, text, integer, boolean, boolean)
    to authenticated;

-- The old three-argument call is preserved by the optional parameter. A null
-- trigger value means "keep the stored account value", so an older dashboard
-- cannot accidentally turn the trigger off while saving the delay/USB settings.
drop function if exists public.update_account_settings(bigint, integer, boolean);

create function public.update_account_settings(
    p_expected_revision bigint,
    p_lock_timer_minutes integer,
    p_usb_trigger_enabled boolean,
    p_lock_trigger_enabled boolean default null
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
           lock_trigger_enabled = coalesce(p_lock_trigger_enabled, s.lock_trigger_enabled),
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

revoke execute on function public.update_account_settings(bigint, integer, boolean, boolean)
    from public, anon, authenticated;
grant execute on function public.update_account_settings(bigint, integer, boolean, boolean)
    to authenticated;

drop function if exists public.device_reconcile(
    uuid, bigint, integer, boolean, bigint, boolean, boolean, boolean, boolean,
    text, smallint, text, text
);

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
    p_last_error_message text default null,
    p_actual_lock_trigger_enabled boolean default null
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
        actual_lock_trigger_enabled,
        timer_remaining_seconds, timer_running,
        debug_mode, reset_supported, remote_enabled,
        app_version, android_sdk, last_error_code, last_error_message,
        timer_sampled_at, last_seen_at, updated_at
    ) values (
        device.id, device.account_id, p_applied_settings_revision,
        p_actual_lock_timer_minutes, p_actual_usb_trigger_enabled,
        p_actual_lock_trigger_enabled,
        p_timer_remaining_seconds, p_timer_running,
        p_debug_mode, p_reset_supported, p_remote_enabled,
        p_app_version, p_android_sdk, p_last_error_code, p_last_error_message,
        server_now, server_now, server_now
    )
    on conflict (device_id) do update set
        applied_settings_revision = excluded.applied_settings_revision,
        actual_lock_timer_minutes = excluded.actual_lock_timer_minutes,
        actual_usb_trigger_enabled = excluded.actual_usb_trigger_enabled,
        actual_lock_trigger_enabled = excluded.actual_lock_trigger_enabled,
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
            'lock_trigger_enabled', settings_row.lock_trigger_enabled,
            'initialized', settings_row.initialized_at is not null
        ),
        'commands', commands
    );
end;
$$;

revoke execute on function public.device_reconcile(
    uuid, bigint, integer, boolean, bigint, boolean, boolean, boolean, boolean,
    text, smallint, text, text, boolean
) from public, anon, authenticated;
grant execute on function public.device_reconcile(
    uuid, bigint, integer, boolean, bigint, boolean, boolean, boolean, boolean,
    text, smallint, text, text, boolean
) to authenticated;
