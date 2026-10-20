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
