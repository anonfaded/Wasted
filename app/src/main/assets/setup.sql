-- Wasted Remote - one-time database setup for a FRESH Supabase project.
-- Paste this whole file into Supabase Dashboard -> SQL Editor -> Run.
-- Run it once. Do not run it again on an existing project and do not mix it with
-- "supabase db push" on the same project.
--
-- App release: 3.0.0 (schema 11)
--
-- This file configures the DATABASE (tables, RLS, RPCs, grants, Realtime, cron).
-- In Authentication settings (Dashboard -> Authentication):
--   1) enable "Allow anonymous sign-ins" (device identities)
--   2) keep the Email provider ON; turn "Confirm email" OFF (direct owner signup, no email)
--   3) enable Authentication > Hooks > Before User Created:
--      hook ON; Hook type Postgres; Postgres schema public;
--      function hook_single_owner_signup; Save
--      (allows anonymous devices, blocks every later email account)
--   4) review the sign-up / sign-in rate limits
--
-- Extensions: pgcrypto is available on Supabase; pg_cron is enabled by the script.
-- Maintenance: daily cleanup keeps command/action history to 180 days and enrollment tokens to
-- 30 days; the dashboard polls visible tabs only and never downloads command history.

create schema if not exists extensions;
create extension if not exists pgcrypto with schema extensions;

-- ===== 20261018125854_remote_schema.sql =====
-- Remote management schema: accounts, devices, enrollment, settings, status, durable commands.
-- Forward-only migration. Applied to the linked project through Supabase MCP in order with the
-- sibling remote_* migrations; never edited after being applied.

create schema if not exists private;

create table public.accounts (
    id uuid primary key references auth.users (id) on delete cascade,
    handle text not null,
    created_at timestamptz not null default now(),
    constraint accounts_handle_length check (char_length(handle) between 3 and 32),
    constraint accounts_handle_trimmed check (handle = btrim(handle)),
    constraint accounts_handle_charset check (handle ~ '^[A-Za-z0-9][A-Za-z0-9_.-]{2,31}$')
);

create unique index accounts_handle_lower_uidx on public.accounts (lower(handle));

create table public.devices (
    id uuid primary key default gen_random_uuid(),
    account_id uuid not null references public.accounts (id) on delete cascade,
    auth_user_id uuid null unique references auth.users (id) on delete set null,
    installation_id uuid not null unique,
    name text not null,
    enrolled_at timestamptz not null default now(),
    revoked_at timestamptz null,
    created_at timestamptz not null default now(),
    updated_at timestamptz not null default now(),
    constraint devices_name_length check (char_length(btrim(name)) between 1 and 80),
    constraint devices_revoked_after_enrolled check (revoked_at is null or revoked_at >= enrolled_at),
    constraint devices_id_account_unique unique (id, account_id),
    constraint devices_active_requires_auth_user check (revoked_at is not null or auth_user_id is not null)
);

create index devices_account_active_idx on public.devices (account_id, created_at desc)
    where revoked_at is null;

create table private.device_enrollments (
    id uuid primary key default gen_random_uuid(),
    account_id uuid not null references public.accounts (id) on delete cascade,
    token_hash bytea not null unique,
    expires_at timestamptz not null,
    consumed_at timestamptz null,
    consumed_by_device_id uuid null references public.devices (id) on delete set null,
    revoked_at timestamptz null,
    created_at timestamptz not null default now(),
    constraint device_enrollments_expiry_after_created check (expires_at > created_at),
    constraint device_enrollments_consumed_after_created check (consumed_at is null or consumed_at >= created_at),
    constraint device_enrollments_revoked_after_created check (revoked_at is null or revoked_at >= created_at),
    constraint device_enrollments_consumed_pair check ((consumed_at is null) = (consumed_by_device_id is null)),
    constraint device_enrollments_not_consumed_and_revoked check (consumed_at is null or revoked_at is null)
);

create index device_enrollments_account_open_idx on private.device_enrollments (account_id, created_at desc)
    where consumed_at is null and revoked_at is null;

create table public.account_settings (
    account_id uuid primary key references public.accounts (id) on delete cascade,
    revision bigint not null default 0,
    lock_timer_minutes integer not null default 10080,
    usb_trigger_enabled boolean not null default false,
    initialized_at timestamptz null,
    updated_by uuid null references auth.users (id) on delete set null,
    updated_at timestamptz not null default now(),
    constraint account_settings_revision_nonnegative check (revision >= 0),
    constraint account_settings_lock_timer_range check (lock_timer_minutes between 1 and 525600)
);

create table public.device_status (
    device_id uuid primary key,
    account_id uuid not null,
    applied_settings_revision bigint not null default 0,
    actual_lock_timer_minutes integer not null,
    actual_usb_trigger_enabled boolean not null,
    timer_remaining_seconds bigint not null,
    timer_running boolean not null,
    debug_mode boolean not null,
    reset_supported boolean not null,
    remote_enabled boolean not null,
    app_version text not null,
    android_sdk smallint not null,
    last_error_code text null,
    last_error_message text null,
    timer_sampled_at timestamptz not null,
    last_seen_at timestamptz not null,
    updated_at timestamptz not null,
    constraint device_status_device_account_fk foreign key (device_id, account_id)
        references public.devices (id, account_id) on delete cascade,
    constraint device_status_applied_revision_nonnegative check (applied_settings_revision >= 0),
    constraint device_status_lock_timer_range check (actual_lock_timer_minutes between 1 and 2147483647),
    constraint device_status_timer_nonnegative check (timer_remaining_seconds >= 0),
    constraint device_status_app_version_length check (char_length(app_version) between 1 and 64),
    constraint device_status_sdk_range check (android_sdk between 24 and 1000),
    constraint device_status_error_code_length check (last_error_code is null or char_length(last_error_code) <= 64),
    constraint device_status_error_message_length check (last_error_message is null or char_length(last_error_message) <= 256)
);

create index device_status_account_seen_idx on public.device_status (account_id, last_seen_at desc);

create table public.account_actions (
    id uuid primary key default gen_random_uuid(),
    account_id uuid not null references public.accounts (id) on delete cascade,
    action_type text not null,
    idempotency_key uuid not null,
    created_by uuid null references auth.users (id) on delete set null,
    created_at timestamptz not null default now(),
    expires_at timestamptz not null,
    constraint account_actions_type_valid check (action_type in ('reset_timer', 'force_reset')),
    constraint account_actions_expiry_after_created check (expires_at > created_at),
    constraint account_actions_idempotency_unique unique (account_id, idempotency_key),
    constraint account_actions_id_account_unique unique (id, account_id)
);

create index account_actions_account_created_idx on public.account_actions (account_id, created_at desc);

create table public.device_commands (
    id uuid primary key default gen_random_uuid(),
    action_id uuid not null,
    device_id uuid not null,
    account_id uuid not null,
    command_type text not null,
    state text not null default 'queued',
    created_at timestamptz not null default now(),
    expires_at timestamptz not null,
    received_at timestamptz null,
    executing_at timestamptz null,
    finished_at timestamptz null,
    result_code text null,
    constraint device_commands_type_valid check (command_type in ('reset_timer', 'force_reset')),
    constraint device_commands_state_valid check (state in (
        'queued', 'received', 'executing', 'applied', 'reset_initiated',
        'debug_blocked', 'rejected', 'failed', 'expired'
    )),
    constraint device_commands_expiry_after_created check (expires_at > created_at),
    constraint device_commands_result_code_length check (result_code is null or char_length(result_code) <= 64),
    constraint device_commands_action_fk foreign key (action_id, account_id)
        references public.account_actions (id, account_id) on delete cascade,
    constraint device_commands_device_fk foreign key (device_id, account_id)
        references public.devices (id, account_id) on delete cascade,
    constraint device_commands_action_device_unique unique (action_id, device_id),
    constraint device_commands_id_account_device_unique unique (id, account_id, device_id)
);

create index device_commands_device_pending_idx on public.device_commands (device_id, created_at)
    where state in ('queued', 'received');

create index device_commands_account_created_idx on public.device_commands (account_id, created_at desc);

create table public.command_events (
    id bigint generated always as identity primary key,
    command_id uuid not null,
    device_id uuid not null,
    account_id uuid not null,
    event_type text not null,
    result_code text null,
    detail text null,
    created_at timestamptz not null default now(),
    constraint command_events_type_valid check (event_type in (
        'queued', 'received', 'executing', 'applied', 'reset_initiated',
        'debug_blocked', 'rejected', 'failed', 'expired'
    )),
    constraint command_events_result_code_length check (result_code is null or char_length(result_code) <= 64),
    constraint command_events_detail_length check (detail is null or char_length(detail) <= 256),
    constraint command_events_command_fk foreign key (command_id, account_id, device_id)
        references public.device_commands (id, account_id, device_id) on delete cascade,
    constraint command_events_command_type_unique unique (command_id, event_type)
);

create index command_events_command_created_idx on public.command_events (command_id, created_at);
create index command_events_account_created_idx on public.command_events (account_id, created_at desc);

-- Command rows must always agree with the action they were created from.
create function private.enforce_command_action_consistency()
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

    return new;
end;
$$;

create trigger device_commands_action_consistency
before insert or update on public.device_commands
for each row execute function private.enforce_command_action_consistency();

-- ===== 20261018133312_remote_rpcs.sql =====
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

-- ===== 20261018133359_remote_rls_grants.sql =====
-- Row Level Security, privileges, and default-privilege hardening.
-- Writes happen exclusively through the SECURITY DEFINER RPCs in 002 (postgres and service_role
-- bypass RLS, so definer code is unaffected). Client roles receive SELECT only, restricted by
-- ownership policies; `anon` keeps no table or function access at all.
-- Forward-only migration.

-- ─── Enable and force RLS on every exposed table ─────────────────────────────

alter table public.accounts enable row level security;
alter table public.accounts force row level security;
alter table public.devices enable row level security;
alter table public.devices force row level security;
alter table public.account_settings enable row level security;
alter table public.account_settings force row level security;
alter table public.device_status enable row level security;
alter table public.device_status force row level security;
alter table public.account_actions enable row level security;
alter table public.account_actions force row level security;
alter table public.device_commands enable row level security;
alter table public.device_commands force row level security;
alter table public.command_events enable row level security;
alter table public.command_events force row level security;

-- ─── Policies (SELECT only; all writes go through RPCs) ──────────────────────

-- Owners read their own account row.
create policy accounts_select_owner on public.accounts
    for select to authenticated
    using (id = (select auth.uid()));

-- Owners read device rows of their account; a device reads its own active row.
create policy devices_select_owner on public.devices
    for select to authenticated
    using (account_id = (select auth.uid()));

create policy devices_select_device on public.devices
    for select to authenticated
    using (auth_user_id = (select auth.uid()) and revoked_at is null);

-- Owners read their settings; a device reads the settings of its bound account.
create policy account_settings_select_owner on public.account_settings
    for select to authenticated
    using (account_id = (select auth.uid()));

create policy account_settings_select_device on public.account_settings
    for select to authenticated
    using (exists (
        select 1
          from public.devices d
         where d.auth_user_id = (select auth.uid())
           and d.account_id = account_settings.account_id
           and d.revoked_at is null
    ));

-- Owners read status rows of their account; devices use the RPC response instead.
create policy device_status_select_owner on public.device_status
    for select to authenticated
    using (account_id = (select auth.uid()));

-- Owners read actions of their account; devices do not read actions.
create policy account_actions_select_owner on public.account_actions
    for select to authenticated
    using (account_id = (select auth.uid()));

-- Owners read commands of their account; a device reads its own commands.
create policy device_commands_select_owner on public.device_commands
    for select to authenticated
    using (account_id = (select auth.uid()));

create policy device_commands_select_device on public.device_commands
    for select to authenticated
    using (exists (
        select 1
          from public.devices d
         where d.id = device_commands.device_id
           and d.auth_user_id = (select auth.uid())
           and d.revoked_at is null
    ));

-- Owners read events of their account; devices use command state from RPCs.
create policy command_events_select_owner on public.command_events
    for select to authenticated
    using (account_id = (select auth.uid()));

-- ─── Table privileges ────────────────────────────────────────────────────────

revoke all on public.accounts, public.devices, public.account_settings, public.device_status,
    public.account_actions, public.device_commands, public.command_events
    from anon, authenticated;

grant select on public.accounts, public.devices, public.account_settings, public.device_status,
    public.account_actions, public.device_commands, public.command_events
    to authenticated;

revoke all on all sequences in schema public from anon, authenticated;

-- ─── Private schema stays invisible to client roles ──────────────────────────

revoke usage on schema private from public, anon, authenticated;
revoke all on all tables in schema private from public, anon, authenticated;

-- ─── Default privileges: future objects are not auto-exposed ─────────────────

alter default privileges for role postgres in schema public
    revoke all on tables from anon, authenticated;
alter default privileges for role postgres in schema public
    revoke all on sequences from anon, authenticated;
alter default privileges for role postgres in schema public
    revoke execute on functions from anon, authenticated;

-- ===== 20261018133558_remote_realtime.sql =====
-- Realtime: publish only the minimum safe tables. Never drop/recreate the publication.
-- Forward-only migration.

do $$
begin
    if not exists (select 1 from pg_publication where pubname = 'supabase_realtime') then
        create publication supabase_realtime;
    end if;
end $$;

do $$
declare
    target text;
    targets text[] := array['account_settings', 'devices', 'device_status', 'device_commands'];
begin
    foreach target in array targets loop
        if not exists (
            select 1
              from pg_publication_tables
             where pubname = 'supabase_realtime'
               and schemaname = 'public'
               and tablename = target
        ) then
            execute format('alter publication supabase_realtime add table public.%I', target);
        end if;
    end loop;
end $$;

-- ===== 20261018133630_remote_maintenance.sql =====
-- Maintenance: one daily cleanup of unbound/revoked anonymous auth identities.
-- Devices keep audit history via devices.auth_user_id on delete set null.
-- Forward-only migration.

create extension if not exists pg_cron;

do $$
begin
    if exists (select 1 from cron.job where jobname = 'wasted-cleanup-anonymous-identities') then
        perform cron.unschedule('wasted-cleanup-anonymous-identities');
    end if;
end $$;

select cron.schedule(
    'wasted-cleanup-anonymous-identities',
    '30 3 * * *',
    $job$
    -- anonymous identities older than 24 hours that never bound to a device
    delete from auth.users u
     where u.is_anonymous is true
       and u.created_at < now() - interval '24 hours'
       and not exists (
           select 1 from public.devices d where d.auth_user_id = u.id
       );

    -- identities belonging only to devices revoked for more than 30 days
    delete from auth.users u
     where u.is_anonymous is true
       and u.id in (
           select d.auth_user_id
             from public.devices d
            where d.auth_user_id is not null
            group by d.auth_user_id
           having bool_and(d.revoked_at is not null)
              and max(d.revoked_at) < now() - interval '30 days'
       );
    $job$
);

-- ===== 20261018133933_remote_private_enrollments_rls.sql =====
-- Defense in depth: private.device_enrollments is unreachable through the Data API
-- (schema not exposed, usage and table privileges revoked from client roles), but RLS is
-- enabled + forced anyway so a future exposure mistake still denies all client access.
-- postgres/service_role bypass RLS, so the definer RPCs are unaffected.
-- Forward-only migration.

alter table private.device_enrollments enable row level security;
alter table private.device_enrollments force row level security;

-- ===== 20261018150719_remote_fk_indexes.sql =====
-- Covering indexes for foreign-key columns flagged by the Supabase missing-FK-index advisor
-- (plan §4: run the check after migrations and add missing referencing-column indexes).
-- Forward-only migration.

create index device_enrollments_consumed_by_device_idx
    on private.device_enrollments (consumed_by_device_id);

create index account_actions_created_by_idx
    on public.account_actions (created_by);

create index account_settings_updated_by_idx
    on public.account_settings (updated_by);

create index command_events_command_fk_idx
    on public.command_events (command_id, account_id, device_id);

create index device_commands_action_fk_idx
    on public.device_commands (action_id, account_id);

create index device_commands_device_fk_idx
    on public.device_commands (device_id, account_id);

create index device_status_device_account_idx
    on public.device_status (device_id, account_id);

-- ===== 20261018164537_remote_policy_merge.sql =====
-- Merge the owner/device policy pairs into single permissive policies: identical visibility
-- matrix (plan §6), one policy evaluation per query, silences the multiple-permissive-policies
-- advisor finding. Forward-only migration.

drop policy devices_select_owner on public.devices;
drop policy devices_select_device on public.devices;
create policy devices_select on public.devices
    for select to authenticated
    using (
        account_id = (select auth.uid())
        or (auth_user_id = (select auth.uid()) and revoked_at is null)
    );

drop policy account_settings_select_owner on public.account_settings;
drop policy account_settings_select_device on public.account_settings;
create policy account_settings_select on public.account_settings
    for select to authenticated
    using (
        account_id = (select auth.uid())
        or exists (
            select 1
              from public.devices d
             where d.auth_user_id = (select auth.uid())
               and d.account_id = account_settings.account_id
               and d.revoked_at is null
        )
    );

drop policy device_commands_select_owner on public.device_commands;
drop policy device_commands_select_device on public.device_commands;
create policy device_commands_select on public.device_commands
    for select to authenticated
    using (
        account_id = (select auth.uid())
        or exists (
            select 1
              from public.devices d
             where d.id = device_commands.device_id
               and d.auth_user_id = (select auth.uid())
               and d.revoked_at is null
        )
    );

-- ===== 20261020131724_remote_debug_mode_commands.sql =====
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

-- ===== 20261021060654_remote_hardening.sql =====
-- Remote hardening:
--   1. Revocation terminalizes commands already in `executing` (outcome may be unknown).
--   2. Account-action idempotency keys are bound to the requested action type/scope.
--   3. Future functions are not auto-executable by PostgreSQL PUBLIC.
--   4. A schema marker for post-install verification.
-- Forward-only migration.

-- ─── 1. Revocation semantics ────────────────────────────────────────────────

create or replace function public.revoke_device(p_device_id uuid)
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

    -- queued/received: definitely not executed
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

    -- executing: the device may already have crossed an irreversible boundary and can no longer
    -- report; record a terminal failed state with an explicit unknown-outcome code.
    with interrupted as (
        update public.device_commands c
           set state = 'failed',
               finished_at = now(),
               result_code = 'device_revoked_during_execution'
         where c.device_id = p_device_id
           and c.state = 'executing'
        returning c.id, c.device_id, c.account_id, c.result_code
    )
    insert into public.command_events (command_id, device_id, account_id, event_type, result_code)
    select id, device_id, account_id, 'failed', result_code from interrupted;
end;
$$;

-- ─── 2. Idempotency binding ──────────────────────────────────────────────────

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
        if existing.action_type <> p_action_type or existing.device_id is not null then
            raise exception 'idempotency key reused for a different action';
        end if;
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
            if existing.action_type <> p_action_type or existing.device_id is not null then
                raise exception 'idempotency key reused for a different action';
            end if;
            return private.action_result_json(existing);
        end if;
        raise;
end;
$$;

-- ─── 3. Future function ACLs ─────────────────────────────────────────────────

alter default privileges for role postgres in schema public
    revoke execute on functions from public;

-- ─── 4. Schema marker ────────────────────────────────────────────────────────

comment on schema public is 'wasted-remote-schema:1';

-- ===== 20261021061300_remote_public_acl.sql =====
-- PostgreSQL grants EXECUTE on new functions to PUBLIC by default. Per-schema default privileges
-- are additive to the global defaults, so the PUBLIC revoke must be global to be effective.
-- Forward-only migration.

alter default privileges for role postgres
    revoke execute on functions from public;

-- ===== 20261021070916_remote_multi_enrollment.sql =====
-- Enrollment tokens become independent per device: creating a new token no longer revokes
-- older unused tokens. Tokens remain 256-bit random, SHA-256 hashed, single-use, and expire
-- after ten minutes. The previous behavior forced users to enroll one device at a time.
-- Forward-only migration.

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
begin
    token := encode(extensions.gen_random_bytes(32), 'hex');

    insert into private.device_enrollments (account_id, token_hash, expires_at)
    values (uid, extensions.digest(token, 'sha256'), now() + interval '10 minutes')
    returning * into enrollment;

    return query select enrollment.id, token, enrollment.expires_at;
end;
$$;

-- ===== 20261021150306_remote_single_owner.sql =====
-- Single-owner guard: a self-hosted project has one dashboard owner. Random authenticated users
-- may still exist in Auth, but they cannot initialize a second dashboard account.
-- Forward-only migration.

create or replace function public.initialize_owner_account(p_handle text)
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

    -- Serialize owner bootstrap and reject a second dashboard account.
    perform pg_catalog.pg_advisory_xact_lock(741852963);
    if exists (select 1 from public.accounts) then
        raise exception 'owner account already initialized';
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
        raise;
end;
$$;

revoke execute on function public.initialize_owner_account(text) from public, anon, authenticated;
grant execute on function public.initialize_owner_account(text) to authenticated;

-- ===== 20261021150716_remote_legacy_revocation_repair.sql =====
-- Terminalize commands left in `executing` by the pre-hardening revoke function. The outcome is
-- unknown, so they are failed, never retried. Idempotent: safe to call repeatedly.
-- Forward-only migration.

create or replace function private.repair_legacy_revoked_commands()
returns integer
language plpgsql
security definer
set search_path = ''
as $$
declare
    repaired integer;
begin
    with stranded as (
        update public.device_commands c
           set state = 'failed',
               finished_at = now(),
               result_code = 'device_revoked_during_execution'
          from public.devices d
         where c.device_id = d.id
           and d.revoked_at is not null
           and c.state = 'executing'
        returning c.id, c.device_id, c.account_id, c.result_code
    ), recorded as (
        insert into public.command_events (command_id, device_id, account_id, event_type, result_code)
        select id, device_id, account_id, 'failed', result_code from stranded
        on conflict (command_id, event_type) do nothing
        returning 1
    )
    select count(*) into repaired from stranded;

    return repaired;
end;
$$;

revoke all on function private.repair_legacy_revoked_commands() from public, anon, authenticated;

select private.repair_legacy_revoked_commands();

-- ===== 20261103222448_remote_owner_handle_update.sql =====
-- Owner profile: allow the signed-in owner to change the dashboard account name.
-- Forward-only migration.

create or replace function public.update_owner_handle(p_handle text)
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

    if trimmed is null
        or char_length(trimmed) < 3
        or char_length(trimmed) > 32
        or trimmed !~ '^[A-Za-z0-9][A-Za-z0-9_.-]{2,31}$' then
        raise exception 'handle must be 3-32 characters: letters, digits, dot, dash, underscore';
    end if;

    update public.accounts a
       set handle = trimmed
     where a.id = uid
     returning * into account;

    if account.id is null then
        raise exception 'owner account missing';
    end if;

    return account;
exception
    when unique_violation then
        raise exception 'handle is already taken';
end;
$$;

revoke execute on function public.update_owner_handle(text) from public, anon, authenticated;
grant execute on function public.update_owner_handle(text) to authenticated;

comment on schema public is 'wasted-remote-schema:2';

-- ===== 20261105054451_remote_display_names.sql =====
-- Display names: allow spaces and normal punctuation, retain trimming and uniqueness.
-- Forward-only migration.

alter table public.accounts drop constraint accounts_handle_length;
alter table public.accounts
    add constraint accounts_handle_length check (char_length(handle) between 1 and 32);

alter table public.accounts drop constraint accounts_handle_charset;
alter table public.accounts
    add constraint accounts_handle_charset check (handle !~ '[[:cntrl:]]');

create or replace function public.initialize_owner_account(p_handle text)
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

    perform pg_catalog.pg_advisory_xact_lock(741852963);
    if exists (select 1 from public.accounts) then
        raise exception 'owner account already initialized';
    end if;

    if trimmed is null
        or char_length(trimmed) < 1
        or char_length(trimmed) > 32
        or trimmed ~ '[[:cntrl:]]' then
        raise exception 'account name must be 1-32 characters and cannot contain control characters';
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
        raise;
end;
$$;

create or replace function public.update_owner_handle(p_handle text)
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

    if trimmed is null
        or char_length(trimmed) < 1
        or char_length(trimmed) > 32
        or trimmed ~ '[[:cntrl:]]' then
        raise exception 'account name must be 1-32 characters and cannot contain control characters';
    end if;

    update public.accounts a
       set handle = trimmed
     where a.id = uid
     returning * into account;

    if account.id is null then
        raise exception 'owner account missing';
    end if;

    return account;
exception
    when unique_violation then
        raise exception 'handle is already taken';
end;
$$;

revoke execute on function public.initialize_owner_account(text) from public, anon, authenticated;
grant execute on function public.initialize_owner_account(text) to authenticated;
revoke execute on function public.update_owner_handle(text) from public, anon, authenticated;
grant execute on function public.update_owner_handle(text) to authenticated;

comment on schema public is 'wasted-remote-schema:3';

-- ===== 20261105064544_remote_single_owner_signup_hook.sql =====
-- Server-side signup gate: allow the first non-anonymous owner and anonymous devices only.
-- Enable this function in Authentication > Hooks > Before User Created.
-- Forward-only migration.

create or replace function public.hook_single_owner_signup(event jsonb)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
    is_anonymous boolean := coalesce((event->'user'->>'is_anonymous')::boolean, false);
begin
    -- Device identities are anonymous and must always be allowed.
    if is_anonymous then
        return '{}'::jsonb;
    end if;

    -- Serialize concurrent signup attempts so only one owner can pass.
    perform pg_catalog.pg_advisory_xact_lock(741852963);

    if exists (select 1 from public.accounts)
        or exists (
            select 1
              from auth.users u
             where u.is_anonymous = false
               and u.email is not null
        ) then
        return jsonb_build_object(
            'error', jsonb_build_object(
                'message', 'This dashboard already has an owner. Sign in instead.',
                'http_code', 403
            )
        );
    end if;

    return '{}'::jsonb;
end;
$$;

grant usage on schema public to supabase_auth_admin;
grant execute on function public.hook_single_owner_signup(jsonb) to supabase_auth_admin;
revoke execute on function public.hook_single_owner_signup(jsonb) from public, anon, authenticated;

comment on schema public is 'wasted-remote-schema:4';

-- ===== 20261105152455_remote_free_plan_guardrails.sql =====
-- Free-plan guardrails: bounded command history, stale enrollment cleanup, and one
-- latest-command row per device for the dashboard instead of refetching command history.

create or replace function public.list_latest_device_commands()
returns table (
    id uuid,
    device_id uuid,
    command_type text,
    state text,
    result_code text,
    created_at timestamptz
)
language sql
security invoker
set search_path = ''
as $$
    select distinct on (c.device_id)
           c.id, c.device_id, c.command_type, c.state, c.result_code, c.created_at
      from public.device_commands c
     order by c.device_id, c.created_at desc, c.id desc;
$$;

revoke all on function public.list_latest_device_commands() from public, anon;
grant execute on function public.list_latest_device_commands() to authenticated;

create or replace function private.cleanup_remote_history()
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
    removed_actions bigint := 0;
    batch_count bigint;
    removed_enrollments bigint := 0;
begin
    -- account_actions cascade to device_commands and command_events.
    -- Batch the first run so a long-neglected project cannot hold one large lock.
    for _ in 1..20 loop
        delete from public.account_actions a
         where a.id in (
             select old.id
               from public.account_actions old
              where old.expires_at < now() - interval '180 days'
              order by old.expires_at
              limit 5000
         );
        get diagnostics batch_count = row_count;
        removed_actions := removed_actions + batch_count;
        exit when batch_count = 0;
    end loop;

    delete from private.device_enrollments e
     where e.created_at < now() - interval '30 days'
       and (e.expires_at < now() or e.consumed_at is not null or e.revoked_at is not null);
    get diagnostics removed_enrollments = row_count;

    raise log 'remote cleanup removed % actions and % enrollments',
        removed_actions, removed_enrollments;
end;
$$;

revoke all on function private.cleanup_remote_history() from public, anon, authenticated;

create extension if not exists pg_cron;

do $$
begin
    if exists (select 1 from cron.job where jobname = 'wasted-cleanup-remote-history') then
        perform cron.unschedule('wasted-cleanup-remote-history');
    end if;
end $$;

select cron.schedule(
    'wasted-cleanup-remote-history',
    '45 3 * * *',
    $job$select private.cleanup_remote_history();$job$
);

-- ===== 20261105152713_remote_schema_marker_5.sql =====
-- The generated setup/verify contract uses the public schema comment as its version marker.
comment on schema public is 'wasted-remote-schema:5';

-- ===== 20261105183606_remote_enrollment_device_delete.sql =====
-- A consumed enrollment token cannot survive its device: setting only
-- consumed_by_device_id to null violates device_enrollments_consumed_pair.
-- Removing the device must remove its enrollment audit row instead.

alter table private.device_enrollments
    drop constraint device_enrollments_consumed_by_device_id_fkey;

alter table private.device_enrollments
    add constraint device_enrollments_consumed_by_device_id_fkey
    foreign key (consumed_by_device_id) references public.devices (id) on delete cascade;

-- ===== 20261105183656_remote_schema_marker_6.sql =====
-- Keep the generated setup/verify contract aligned with the current schema release.
comment on schema public is 'wasted-remote-schema:6';

-- ===== 20261105230000_remote_lock_trigger.sql =====
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

-- ===== 20261105230001_remote_schema_marker_7.sql =====
comment on schema public is 'wasted-remote-schema:7';

-- ===== 20261105233000_remote_lock_command.sql =====
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

-- ===== 20261105233001_remote_schema_marker_8.sql =====
comment on schema public is 'wasted-remote-schema:8';

-- ===== 20261106120000_remote_device_settings_targets_schema.sql =====
-- Production remote model:
--   * global account_settings remain the baseline
--   * device_settings holds nullable per-device overrides; NULL means inherit
--   * commands have explicit target rows instead of an implicit account-wide fan-out
--   * device_status reports battery and both applied settings revisions
-- Forward-only migration; the remote area is unreleased, so no compatibility aliases.

-- ─── 1. Per-device settings overrides ────────────────────────────────────────

create table public.device_settings (
    device_id uuid primary key,
    account_id uuid not null,
    revision bigint not null default 0,
    lock_trigger_enabled boolean null,
    lock_timer_minutes integer null,
    usb_trigger_enabled boolean null,
    updated_by uuid null references auth.users (id) on delete set null,
    updated_at timestamptz not null default now(),
    constraint device_settings_device_account_fk foreign key (device_id, account_id)
        references public.devices (id, account_id) on delete cascade,
    constraint device_settings_revision_nonnegative check (revision >= 0),
    constraint device_settings_lock_timer_range check (
        lock_timer_minutes is null
        or lock_timer_minutes between 1 and 525600
    )
);

create index device_settings_account_idx on public.device_settings (account_id);

-- ─── 2. Device status: battery and dual applied revisions ────────────────────

alter table public.device_status
    rename column applied_settings_revision to applied_global_settings_revision;

alter table public.device_status
    add column applied_device_settings_revision bigint not null default 0,
    add column battery_percent smallint null,
    add column battery_charging boolean null,
    add column battery_sampled_at timestamptz null,
    add column settings_applied_at timestamptz null;

alter table public.device_status
    add constraint device_status_applied_device_revision_nonnegative
        check (applied_device_settings_revision >= 0),
    add constraint device_status_battery_percent_range
        check (battery_percent is null or battery_percent between 0 and 100);

-- ─── 3. Command targets ─────────────────────────────────────────────────────

create table public.account_action_targets (
    action_id uuid not null,
    account_id uuid not null,
    device_id uuid not null,
    created_at timestamptz not null default now(),
    primary key (action_id, device_id),
    constraint account_action_targets_action_account_fk
        foreign key (action_id, account_id)
        references public.account_actions (id, account_id) on delete cascade,
    constraint account_action_targets_device_account_fk
        foreign key (device_id, account_id)
        references public.devices (id, account_id) on delete cascade
);

create index account_action_targets_device_idx
    on public.account_action_targets (device_id, account_id);

alter table public.account_actions
    add column target_scope text null;

update public.account_actions
   set target_scope = case
       when device_id is null then 'all'
       else 'selected'
   end;

alter table public.account_actions
    alter column target_scope set not null,
    add constraint account_actions_target_scope_valid
        check (target_scope in ('all', 'selected'));

-- Preserve existing command history as explicit targets before dropping device_id.
insert into public.account_action_targets (action_id, account_id, device_id)
select a.id, a.account_id, a.device_id
  from public.account_actions a
 where a.device_id is not null
on conflict (action_id, device_id) do nothing;

insert into public.account_action_targets (action_id, account_id, device_id)
select c.action_id, c.account_id, c.device_id
  from public.device_commands c
on conflict (action_id, device_id) do nothing;

alter table public.account_actions
    drop constraint account_actions_device_scope_valid;

alter table public.account_actions
    drop constraint account_actions_device_fk;

drop index public.account_actions_device_idx;

alter table public.account_actions
    drop column device_id;

-- ─── 4. RLS and grants ──────────────────────────────────────────────────────

alter table public.device_settings enable row level security;
alter table public.device_settings force row level security;
alter table public.account_action_targets enable row level security;
alter table public.account_action_targets force row level security;

create policy device_settings_select on public.device_settings
    for select
    to authenticated
    using (
        account_id = (select auth.uid())
        or exists (
            select 1
              from public.devices d
             where d.id = device_settings.device_id
               and d.auth_user_id = (select auth.uid())
               and d.revoked_at is null
        )
    );

create policy account_action_targets_select_owner on public.account_action_targets
    for select
    to authenticated
    using (account_id = (select auth.uid()));

grant select on public.device_settings, public.account_action_targets
    to authenticated;

revoke all on public.device_settings, public.account_action_targets from anon;

-- ─── 5. Realtime ────────────────────────────────────────────────────────────

do $$
begin
    if not exists (
        select 1
          from pg_publication_tables
         where pubname = 'supabase_realtime'
           and schemaname = 'public'
           and tablename = 'device_settings'
    ) then
        alter publication supabase_realtime add table public.device_settings;
    end if;
end;
$$;

-- ===== 20261106120100_remote_device_settings_targets_rpcs.sql =====
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

-- ===== 20261106120110_remote_action_targets_rpcs.sql =====
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

-- ===== 20261106120200_remote_schema_marker_9.sql =====
comment on schema public is 'wasted-remote-schema:9';

-- ===== 20261106120400_remote_supersede_pending_commands.sql =====
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

-- ===== 20261106120500_remote_schema_marker_10.sql =====
comment on schema public is 'wasted-remote-schema:10';

-- ===== 20261106120600_remote_supersede_command_families.sql =====
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

-- ===== 20261106120700_remote_schema_marker_11.sql =====
comment on schema public is 'wasted-remote-schema:11';

notify pgrst, 'reload schema';
