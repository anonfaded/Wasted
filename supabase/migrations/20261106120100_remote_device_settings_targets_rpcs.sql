-- Remote RPCs for production per-device settings, battery, and targeted commands.
-- All remote RPCs are breaking: the unreleased client is updated in lockstep, so no
-- compatibility overloads or nullable compatibility defaults are kept.

-- ─── 1. Effective settings resolver ─────────────────────────────────────────

create function private.resolve_device_settings(p_device_id uuid)
returns table (
    global_revision bigint,
    device_revision bigint,
    initialized boolean,
    lock_trigger_enabled boolean,
    lock_timer_minutes integer,
    usb_trigger_enabled boolean,
    lock_trigger_overridden boolean,
    lock_timer_overridden boolean,
    usb_trigger_overridden boolean
)
language sql
stable
security definer
set search_path = ''
as $$
    select
        gs.revision,
        coalesce(ds.revision, 0),
        gs.initialized_at is not null,
        coalesce(ds.lock_trigger_enabled, gs.lock_trigger_enabled),
        coalesce(ds.lock_timer_minutes, gs.lock_timer_minutes),
        coalesce(ds.usb_trigger_enabled, gs.usb_trigger_enabled),
        ds.lock_trigger_enabled is not null,
        ds.lock_timer_minutes is not null,
        ds.usb_trigger_enabled is not null
      from public.devices d
      join public.account_settings gs on gs.account_id = d.account_id
      left join public.device_settings ds on ds.device_id = d.id
     where d.id = p_device_id;
$$;

-- ─── 2. Owner effective-settings reads and writes ───────────────────────────

create function public.list_device_effective_settings()
returns table (
    device_id uuid,
    account_id uuid,
    device_name text,
    global_revision bigint,
    device_revision bigint,
    initialized boolean,
    lock_trigger_enabled boolean,
    lock_timer_minutes integer,
    usb_trigger_enabled boolean,
    lock_trigger_overridden boolean,
    lock_timer_overridden boolean,
    usb_trigger_overridden boolean,
    settings_applied_at timestamptz,
    applied_global_settings_revision bigint,
    applied_device_settings_revision bigint,
    last_seen_at timestamptz
)
language sql
stable
security definer
set search_path = ''
as $$
    select d.id,
           d.account_id,
           d.name,
           r.global_revision,
           r.device_revision,
           r.initialized,
           r.lock_trigger_enabled,
           r.lock_timer_minutes,
           r.usb_trigger_enabled,
           r.lock_trigger_overridden,
           r.lock_timer_overridden,
           r.usb_trigger_overridden,
           s.settings_applied_at,
           s.applied_global_settings_revision,
           s.applied_device_settings_revision,
           s.last_seen_at
      from public.devices d
      cross join lateral private.resolve_device_settings(d.id) r
      left join public.device_status s on s.device_id = d.id
     where d.account_id = private.require_owner()
       and d.revoked_at is null
     order by d.created_at;
$$;

create function public.update_device_settings(
    p_device_id uuid,
    p_expected_revision bigint,
    p_patch jsonb
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
    uid uuid := private.require_owner();
    device public.devices;
    existing public.device_settings;
    effective record;
    next_trigger boolean;
    next_timer integer;
    next_usb boolean;
begin
    if p_device_id is null then
        raise exception 'device id is required';
    end if;
    if p_expected_revision is null or p_expected_revision < 0 then
        raise exception 'expected revision must be >= 0';
    end if;
    if p_patch is null or jsonb_typeof(p_patch) <> 'object' then
        raise exception 'settings patch must be a JSON object';
    end if;
    if p_patch = '{}'::jsonb then
        raise exception 'settings patch must include at least one setting';
    end if;
    if exists (
        select 1
          from jsonb_object_keys(p_patch) key
         where key not in ('lock_trigger_enabled', 'lock_timer_minutes', 'usb_trigger_enabled')
    ) then
        raise exception 'unsupported device setting';
    end if;

    if p_patch ? 'lock_trigger_enabled'
        and jsonb_typeof(p_patch -> 'lock_trigger_enabled') not in ('boolean', 'null') then
        raise exception 'lock trigger override must be boolean or null';
    end if;
    if p_patch ? 'usb_trigger_enabled'
        and jsonb_typeof(p_patch -> 'usb_trigger_enabled') not in ('boolean', 'null') then
        raise exception 'usb trigger override must be boolean or null';
    end if;
    if p_patch ? 'lock_timer_minutes' then
        if jsonb_typeof(p_patch -> 'lock_timer_minutes') not in ('number', 'null') then
            raise exception 'lock timer override must be an integer or null';
        end if;
        if jsonb_typeof(p_patch -> 'lock_timer_minutes') = 'number'
            and (
                (p_patch ->> 'lock_timer_minutes') !~ '^[0-9]+$'
                or (p_patch ->> 'lock_timer_minutes')::integer < 1
                or (p_patch ->> 'lock_timer_minutes')::integer > 525600
            ) then
            raise exception 'lock timer override must be between 1 and 525600';
        end if;
    end if;

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
      from public.device_settings ds
     where ds.device_id = device.id
     for update;

    if p_expected_revision <> coalesce(existing.revision, 0) then
        raise exception 'device settings revision conflict';
    end if;

    next_trigger := case
        when p_patch ? 'lock_trigger_enabled'
            then (p_patch ->> 'lock_trigger_enabled')::boolean
        else existing.lock_trigger_enabled
    end;
    next_timer := case
        when p_patch ? 'lock_timer_minutes'
            then (p_patch ->> 'lock_timer_minutes')::integer
        else existing.lock_timer_minutes
    end;
    next_usb := case
        when p_patch ? 'usb_trigger_enabled'
            then (p_patch ->> 'usb_trigger_enabled')::boolean
        else existing.usb_trigger_enabled
    end;

    if existing.device_id is null then
        insert into public.device_settings (
            device_id, account_id, revision,
            lock_trigger_enabled, lock_timer_minutes, usb_trigger_enabled,
            updated_by, updated_at
        ) values (
            device.id, uid, 1,
            next_trigger, next_timer, next_usb,
            uid, now()
        );
    else
        update public.device_settings ds
           set lock_trigger_enabled = next_trigger,
               lock_timer_minutes = next_timer,
               usb_trigger_enabled = next_usb,
               revision = ds.revision + 1,
               updated_by = uid,
               updated_at = now()
         where ds.device_id = device.id;
    end if;

    select * into effective
      from private.resolve_device_settings(device.id);

    return jsonb_build_object(
        'device_id', device.id,
        'global_revision', effective.global_revision,
        'device_revision', effective.device_revision,
        'initialized', effective.initialized,
        'lock_trigger_enabled', effective.lock_trigger_enabled,
        'lock_timer_minutes', effective.lock_timer_minutes,
        'usb_trigger_enabled', effective.usb_trigger_enabled,
        'lock_trigger_overridden', effective.lock_trigger_overridden,
        'lock_timer_overridden', effective.lock_timer_overridden,
        'usb_trigger_overridden', effective.usb_trigger_overridden
    );
end;
$$;

revoke execute on function public.list_device_effective_settings()
    from public, anon, authenticated;
revoke execute on function public.update_device_settings(uuid, bigint, jsonb)
    from public, anon, authenticated;
grant execute on function public.list_device_effective_settings() to authenticated;
grant execute on function public.update_device_settings(uuid, bigint, jsonb) to authenticated;

-- ─── 3. Account settings: no compatibility defaults ─────────────────────────

drop function if exists public.update_account_settings(bigint, integer, boolean, boolean);

create function public.update_account_settings(
    p_expected_revision bigint,
    p_lock_timer_minutes integer,
    p_usb_trigger_enabled boolean,
    p_lock_trigger_enabled boolean
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
    if p_lock_trigger_enabled is null then
        raise exception 'lock trigger flag is required';
    end if;

    update public.account_settings s
       set lock_timer_minutes = p_lock_timer_minutes,
           usb_trigger_enabled = p_usb_trigger_enabled,
           lock_trigger_enabled = p_lock_trigger_enabled,
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

-- ─── 4. Enrollment: all local seed values are required ──────────────────────

drop function if exists public.claim_device_enrollment(text, uuid, text, integer, boolean, boolean);

create function public.claim_device_enrollment(
    p_token text,
    p_installation_id uuid,
    p_device_name text,
    p_local_lock_timer_minutes integer,
    p_local_usb_trigger_enabled boolean,
    p_local_lock_trigger_enabled boolean
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
    if p_local_lock_trigger_enabled is null then
        raise exception 'lock trigger flag is required';
    end if;

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
               lock_trigger_enabled = p_local_lock_trigger_enabled,
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

-- ─── 5. Reconcile: required battery fields and dual revisions ───────────────

drop function if exists public.device_reconcile(
    uuid, bigint, integer, boolean, bigint, boolean, boolean, boolean, boolean,
    text, smallint, text, text, boolean
);

create function public.device_reconcile(
    p_device_id uuid,
    p_applied_global_settings_revision bigint,
    p_applied_device_settings_revision bigint,
    p_actual_lock_timer_minutes integer,
    p_actual_usb_trigger_enabled boolean,
    p_actual_lock_trigger_enabled boolean,
    p_timer_remaining_seconds bigint,
    p_timer_running boolean,
    p_debug_mode boolean,
    p_reset_supported boolean,
    p_remote_enabled boolean,
    p_battery_percent smallint,
    p_battery_charging boolean,
    p_app_version text,
    p_android_sdk smallint,
    p_last_error_code text,
    p_last_error_message text
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
    device public.devices;
    settings_row record;
    old_status record;
    commands jsonb;
    server_now timestamptz := now();
    next_settings_applied_at timestamptz;
    next_battery_sampled_at timestamptz;
begin
    device := private.require_active_device(p_device_id);

    if p_applied_global_settings_revision is null or p_applied_global_settings_revision < 0 then
        raise exception 'applied global settings revision must be >= 0';
    end if;
    if p_applied_device_settings_revision is null or p_applied_device_settings_revision < 0 then
        raise exception 'applied device settings revision must be >= 0';
    end if;
    if p_actual_lock_timer_minutes is null or p_actual_lock_timer_minutes < 1 then
        raise exception 'actual lock timer minutes must be >= 1';
    end if;
    if p_timer_remaining_seconds is null or p_timer_remaining_seconds < 0 then
        raise exception 'timer remaining seconds must be >= 0';
    end if;
    if p_battery_percent is not null and (p_battery_percent < 0 or p_battery_percent > 100) then
        raise exception 'battery percent must be between 0 and 100';
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

    select device_id,
           applied_global_settings_revision,
           applied_device_settings_revision,
           settings_applied_at
      into old_status
      from public.device_status s
     where s.device_id = device.id;

    next_settings_applied_at := case
        when old_status.device_id is null then server_now
        when old_status.applied_global_settings_revision
             is distinct from p_applied_global_settings_revision
          or old_status.applied_device_settings_revision
             is distinct from p_applied_device_settings_revision
            then server_now
        else coalesce(old_status.settings_applied_at, server_now)
    end;
    next_battery_sampled_at := case
        when p_battery_percent is null and p_battery_charging is null then null
        else server_now
    end;

    insert into public.device_status (
        device_id, account_id,
        applied_global_settings_revision, applied_device_settings_revision,
        actual_lock_timer_minutes, actual_usb_trigger_enabled,
        actual_lock_trigger_enabled,
        timer_remaining_seconds, timer_running,
        debug_mode, reset_supported, remote_enabled,
        battery_percent, battery_charging, battery_sampled_at,
        app_version, android_sdk, last_error_code, last_error_message,
        timer_sampled_at, last_seen_at, updated_at, settings_applied_at
    ) values (
        device.id, device.account_id,
        p_applied_global_settings_revision, p_applied_device_settings_revision,
        p_actual_lock_timer_minutes, p_actual_usb_trigger_enabled,
        p_actual_lock_trigger_enabled,
        p_timer_remaining_seconds, p_timer_running,
        p_debug_mode, p_reset_supported, p_remote_enabled,
        p_battery_percent, p_battery_charging, next_battery_sampled_at,
        p_app_version, p_android_sdk, p_last_error_code, p_last_error_message,
        server_now, server_now, server_now, next_settings_applied_at
    )
    on conflict (device_id) do update set
        applied_global_settings_revision = excluded.applied_global_settings_revision,
        applied_device_settings_revision = excluded.applied_device_settings_revision,
        actual_lock_timer_minutes = excluded.actual_lock_timer_minutes,
        actual_usb_trigger_enabled = excluded.actual_usb_trigger_enabled,
        actual_lock_trigger_enabled = excluded.actual_lock_trigger_enabled,
        timer_remaining_seconds = excluded.timer_remaining_seconds,
        timer_running = excluded.timer_running,
        debug_mode = excluded.debug_mode,
        reset_supported = excluded.reset_supported,
        remote_enabled = excluded.remote_enabled,
        battery_percent = excluded.battery_percent,
        battery_charging = excluded.battery_charging,
        battery_sampled_at = excluded.battery_sampled_at,
        app_version = excluded.app_version,
        android_sdk = excluded.android_sdk,
        last_error_code = excluded.last_error_code,
        last_error_message = excluded.last_error_message,
        timer_sampled_at = excluded.timer_sampled_at,
        last_seen_at = excluded.last_seen_at,
        updated_at = excluded.updated_at,
        settings_applied_at = excluded.settings_applied_at;

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
      from private.resolve_device_settings(device.id);

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
            'global_revision', settings_row.global_revision,
            'device_revision', settings_row.device_revision,
            'initialized', settings_row.initialized,
            'lock_timer_minutes', settings_row.lock_timer_minutes,
            'usb_trigger_enabled', settings_row.usb_trigger_enabled,
            'lock_trigger_enabled', settings_row.lock_trigger_enabled
        ),
        'commands', commands
    );
end;
$$;

revoke execute on function public.device_reconcile(
    uuid, bigint, bigint, integer, boolean, boolean, bigint, boolean,
    boolean, boolean, boolean, smallint, boolean, text, smallint, text, text
) from public, anon, authenticated;
grant execute on function public.device_reconcile(
    uuid, bigint, bigint, integer, boolean, boolean, bigint, boolean,
    boolean, boolean, boolean, smallint, boolean, text, smallint, text, text
) to authenticated;
