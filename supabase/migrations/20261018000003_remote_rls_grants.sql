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
