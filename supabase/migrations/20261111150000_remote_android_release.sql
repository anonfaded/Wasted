-- Store the Android release string reported by the device instead of deriving it from the SDK.
-- The app sends Build.VERSION.RELEASE; the dashboard displays that value directly.

alter table public.device_status
    add column android_release text not null default 'unknown';

alter table public.device_status
    add constraint device_status_android_release_length
        check (char_length(android_release) between 1 and 32);

drop function if exists public.device_reconcile(
    uuid, bigint, bigint, integer, boolean, boolean, bigint, boolean,
    boolean, boolean, boolean, smallint, boolean, text, smallint, text, text
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
    p_android_release text,
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
    if p_android_release is null
        or char_length(p_android_release) < 1
        or char_length(p_android_release) > 32 then
        raise exception 'android release must be 1-32 characters';
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
        app_version, android_sdk, android_release, last_error_code, last_error_message,
        timer_sampled_at, last_seen_at, updated_at, settings_applied_at
    ) values (
        device.id, device.account_id,
        p_applied_global_settings_revision, p_applied_device_settings_revision,
        p_actual_lock_timer_minutes, p_actual_usb_trigger_enabled,
        p_actual_lock_trigger_enabled,
        p_timer_remaining_seconds, p_timer_running,
        p_debug_mode, p_reset_supported, p_remote_enabled,
        p_battery_percent, p_battery_charging, next_battery_sampled_at,
        p_app_version, p_android_sdk, p_android_release, p_last_error_code, p_last_error_message,
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
        android_release = excluded.android_release,
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
    boolean, boolean, boolean, smallint, boolean, text, smallint, text, text, text
) from public, anon, authenticated;
grant execute on function public.device_reconcile(
    uuid, bigint, bigint, integer, boolean, boolean, bigint, boolean,
    boolean, boolean, boolean, smallint, boolean, text, smallint, text, text, text
) to authenticated;
