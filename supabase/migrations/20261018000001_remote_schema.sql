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
