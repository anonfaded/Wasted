# Database schema and RPCs

Self-sufficient reference for the Supabase backend. Generated install/update SQL lives in
`supabase/releases/<version>/`; migration policy is in
[migrations-and-releases.md](./migrations-and-releases.md).

## Tables (public unless noted)

| Table | Purpose | Key points |
| --- | --- | --- |
| `accounts` | Owner profile | `id` = auth user id; unique handle (case-insensitive), 3–32 chars |
| `devices` | Enrolled devices | `account_id` FK; unique `installation_id`; `auth_user_id` (anonymous); `revoked_at`; unique `(id, account_id)` |
| `account_settings` | Desired account state | `revision` (monotonic), `lock_timer_minutes` (1–525600), `usb_trigger_enabled`, `initialized_at` |
| `device_status` | Last reported device state | One row per device: applied revision, actual timer/USB, timer remaining/running, Debug Mode, reset support, remote enabled, app version, Android SDK, last error, `timer_sampled_at`, `last_seen_at` |
| `account_actions` | Command batches | `action_type`, `idempotency_key` unique per account, `expires_at`, nullable `device_id` (set only for per-device debug actions) |
| `device_commands` | Durable commands | One row per device/action; `command_type`, `state`, timestamps, `result_code`; unique `(action_id, device_id)` |
| `command_events` | Append-only audit | One event per state per command; `event_type`, `result_code`, `detail` |
| `private.device_enrollments` | Enrollment tokens | SHA-256 token hash, 10-minute expiry, consumed/revoked timestamps; deny-all RLS (RPC access only) |

Relationships: accounts → devices/settings/actions; actions → commands; devices → status/commands/
events; events reference `(command_id, account_id, device_id)`.

## Constraints and indexes (highlights)

- Command/action consistency trigger: a command's `account_id`, `command_type`, and `expires_at`
  must match its action; per-device actions also require a matching `device_id`.
- Idempotency keys are bound to the action type/scope: reusing a key for a different action/device
  raises an error instead of returning the old action.
- Revoking a device terminalizes `queued`/`received` commands as `rejected` and `executing` commands
  as `failed` with `device_revoked_during_execution` (the outcome may be unknown).
- `reset_initiated` is terminal and written before the destructive call; there is no post-wipe
  acknowledgement (the device may be erased).
- Command state allowlist and per-type terminal states (see [remote-protocol.md](./remote-protocol.md)).
- Partial pending-command index `(device_id, created_at) where state in ('queued','received')`.
- Status index `(account_id, last_seen_at desc)`; account action/command history indexes.
- FK-covering indexes on action/device/event relationships.

## Row-level security

- RLS is **enabled and forced** on every remote table.
- `authenticated` gets `SELECT` only; `anon` has no table access; `private` schema usage is revoked.
- Policies:
  - owner sees rows where `account_id = auth.uid()`;
  - a device sees its own `devices`, `account_settings`, and `device_commands` rows via
    `devices.auth_user_id = auth.uid()` and `revoked_at is null`; devices do **not** read
    `device_status`, `account_actions`, or `command_events` (they receive status via reconcile).
- No INSERT/UPDATE/DELETE policies; all writes go through SECURITY DEFINER RPCs.
- Default privileges are stripped so future tables are not auto-exposed.

## RPC catalog

All functions are `security definer`, `search_path = ''`, and executable only by `authenticated`;
anonymous callers are distinguished by the JWT `is_anonymous` claim. Private helpers are revoked
from all roles.

### Owner RPCs

| RPC | Purpose / authorization |
| --- | --- |
| `initialize_owner_account(p_handle)` | Creates the account + settings row; idempotent per auth user |
| `create_device_enrollment()` | Issues a 64-hex single-use token, 10-minute expiry; tokens are independent per device |
| `rename_device(p_device_id, p_name)` | Rename an owned active device |
| `revoke_device(p_device_id)` | Revokes device; queued/received commands become `rejected`/`device_revoked`; `executing` commands become `failed`/`device_revoked_during_execution` (outcome unknown); terminal rows are preserved |
| `update_account_settings(p_expected_revision, p_lock_timer_minutes, p_usb_trigger_enabled)` | Revision-protected settings update |
| `create_account_action(p_action_type, p_idempotency_key)` | Account-wide action (`reset_timer`/`force_reset`), fans out to active devices |
| `set_device_debug_mode(p_device_id, p_debug_mode, p_idempotency_key)` | Per-device debug command, one command, owner-only |
| `expire_account_commands()` | Owner-triggered expiry of overdue queued/received commands |

### Device RPCs

| RPC | Purpose / authorization |
| --- | --- |
| `claim_device_enrollment(p_token, p_installation_id, p_device_name, p_local_lock_timer_minutes, p_local_usb_trigger_enabled)` | Anonymous identity claims a token; binds device; seeds account settings on first claim; replay-safe per installation |
| `device_reconcile(p_device_id, ...)` | Upserts status, lazily expires overdue commands, returns server time, device, settings, pending commands |
| `device_transition_command(p_device_id, p_command_id, p_expected_state, p_new_state, p_result_code, p_detail)` | Compare-and-set state transition with legal matrix, expiry gate, audit event |

## Realtime

Publication `supabase_realtime` contains exactly: `account_settings`, `devices`, `device_status`,
`device_commands`. Clients subscribe with filters (device id or account id) and treat events only as
invalidation signals.

## Maintenance

A `pg_cron` job (`wasted-cleanup-anonymous-identities`) removes unbound/stale anonymous identities.
If `pg_cron` is unavailable, enable it under Database → Extensions before running setup.

## Generated SQL

- Fresh install: `supabase/releases/<current>/setup.sql` (all migrations + extensions guard).
- Upgrade: `supabase/releases/<current>/update-from-<old>-to-<current>.sql`.
- Checks: `verify.sql`; tests in `supabase/tests/` (schema, RLS, RPC, concurrency).

Never run setup on an existing project or edit applied migrations.
