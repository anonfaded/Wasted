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
