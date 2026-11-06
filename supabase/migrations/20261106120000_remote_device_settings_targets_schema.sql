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
