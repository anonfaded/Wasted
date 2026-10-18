# Wasted Remote Control — End-to-End Implementation Plan

## 0. How to execute this plan

This is the implementation source of truth for the local archived client materials: `archive/wasted update.txt`, `archive/portable_android_control_panel_simple_guide.pdf`, and `archive/portable_android_control_panel_technical_guide.pdf`. These source materials are intentionally Git-ignored; this plan is the tracked implementation record. Firebase in the guides is intentionally replaced by Supabase Auth, Postgres, RLS, RPCs, and Realtime. There is no FCM, Firebase, Edge Function, queue service, custom backend server, PWA, or custom-domain requirement.

Rules for the implementing agent:

- Execute phases in order. Do not start a later phase until the current gate passes.
- Keep this checklist updated with evidence: test command, result, device/API, and saved log path.
- All remote Supabase inspection and mutations use Supabase MCP. Every database change must also exist in a committed migration; never leave dashboard-only schema drift.
- Before adding/upgrading a dependency, verify its current stable documentation with Context7/official sources. Pin exact stable versions and commit lock/verification data. No alpha, beta, RC, snapshot, dynamic, or `latest` dependency.
- Preserve unrelated user changes. Remote management is additive and defaults OFF.
- If a gate fails or an existing feature changes unexpectedly, stop, diagnose, update this plan, and fix the regression before continuing.
- A plan cannot mathematically guarantee zero regressions. The isolation rules and mandatory regression gates below are the proof required before release.
- Modify this plan incrementally with `apply_patch`; preserve completed decisions and evidence instead of deleting/recreating the document.

## 1. Frozen product and architecture decisions

- Minimum Android version is Android 7 / API 24 (`minSdk 24`). Target/compile remain on the latest stable project-compatible SDK.
- Existing Device Admin, local triggers, inactivity timer, USB behavior, foreground service, P2P, Shizuku, and offline behavior remain available. Do not remove or replace them.
- The existing `ForegroundService` owns one Supabase Realtime connection when Remote Management is enabled and the user is unlocked. Do not create a second permanent service.
- Supabase Postgres is authoritative. Realtime events are only `sync required` signals; Android and the dashboard always refetch durable state. Never execute a Realtime payload directly.
- The dashboard is a lightweight static build (semantic HTML, CSS, ES modules, no UI framework/server runtime). `dist/` must be copy-deployable to any HTTPS static host.
- Owner identity is a normal non-anonymous Supabase Auth email/password user. The dashboard provides explicit **Sign In** and **Create Account** flows as required by the archived client specification; a failed sign-in never silently creates an account. `handle` is the account display identifier, not a substitute for the Auth identity.
- The client did not request anonymous sign-in as a user-facing feature. Internally, each Android installation uses a separate Supabase anonymous Auth identity solely to satisfy the requirement for a unique per-device credential without storing the owner's password. An anonymous identity has no account/device access until an authenticated owner creates a one-time enrollment token and the claim RPC binds it; all unbound access is denied.
- Debug Mode is a device-local, fail-closed safety boundary. The website may display it but cannot disable it.
- Account-wide remote settings initially cover only the existing Lock Timer and USB Trigger. Do not expose wipe flags, P2P, Recast, Debug Mode, or unrelated preferences remotely.
- Ship one normal public APK. Remote Management is present but defaults OFF and unconfigured; it performs no Supabase work until the user explicitly supplies valid configuration, enrolls, and enables it.

### Requirements boundary

- Implement exactly the client-facing scope from the archived client specification (`archive/wasted update.txt`): configurable website access, Sign In/Create Account, multi-device registration/status, Lock Timer and USB Trigger sync, Reset Timer, Force Reset, local Debug Mode, optional notifications, offline-safe reconciliation, and a portable static website.
- Supabase Auth/Postgres/RLS/RPC/Realtime, per-device anonymous Auth identities, enrollment tokens, encryption, idempotency, and retry journals are implementation/security mechanisms required to deliver that scope; they are not extra user-facing products.
- Out of scope unless later requested: Firebase/FCM, custom backend/Edge Functions, PWA/custom domain, billing/organization UI, production SMTP/password recovery, production-data backup service, or live-data migration tooling.
- Do not add, remove, or restrict client-facing behavior from assumptions. Validate all Supabase facts and linked-project state with Supabase MCP; if a product decision is genuinely unresolved, stop and ask instead of choosing it silently.

```text
Static dashboard
  ├─ Supabase Auth
  ├─ owner SELECTs protected by RLS
  ├─ all mutations through narrow RPCs
  └─ Realtime invalidation → authoritative refetch
                         │
                         v
Supabase
  ├─ Auth: owner users + restricted anonymous device users
  ├─ Postgres: settings, devices, durable commands, status, events
  ├─ RLS/grants: account/device isolation
  ├─ RPCs: validation, idempotency, legal state transitions
  └─ Realtime publication: minimum safe tables only
                         │
                         v
Existing Android ForegroundService
  ├─ RemoteSyncCoordinator (one instance/single-flight)
  ├─ Realtime signal → device_reconcile()
  ├─ encrypted credential store + encrypted command journal/outbox
  ├─ shared LocalSettingsApplier and TimerCoordinator
  └─ shared ResetExecutor → DestructiveActionGate → DeviceAdminManager
```

### Delivery limits

Near-immediate delivery is expected while the foreground service, authenticated Realtime socket, and network are alive. Delivery is not guaranteed while offline, force-stopped, before user unlock, after an OEM/OS kill, or under restrictive battery policy. Commands remain durable until expiry and reconcile when execution becomes possible. Only the Phase 4 real-device soak establishes acceptable reliability.

## 2. Verified technology baseline (17 October 2026)

Use this stable baseline; re-check it with Context7 before editing build files and change it only if a documented compatibility failure is proven:

- Android: existing Views/ViewBinding; no Compose rewrite. `compileSdk/targetSdk 36`, `minSdk 24`, JDK 17 bytecode.
- Kotlin `2.4.21`; KSP `2.3.12`; keep the current stable AGP/Gradle pair if the Phase 1 dependency spike passes.
- Supabase Kotlin BOM `3.8.0`: only `auth-kt`, `postgrest-kt`, and `realtime-kt`.
- Ktor `3.5.1` with the OkHttp engine and WebSocket support; do not introduce CIO beside the existing OkHttp stack.
- Enable official core-library desugaring because supabase-kt defaults to API 26.
- WorkManager `2.12.0` (stable, API 24 minimum) for recovery only.
- Existing Room `2.8.4`; SQLCipher for Android `4.19.1` with Room 2 `SupportOpenHelperFactory` for the separate remote database.
- Existing Tink Android `1.21.0`/Android Keystore for preferences, Supabase session storage, and SQLCipher key wrapping.
- Website: `@supabase/supabase-js` `2.118.0`; bundle it locally into `dist/`, never load it from a runtime CDN.

Phase 1 must prove dependency resolution, debug/release compilation, R8 rules, API 24 installation, SQLCipher 16 KB page/device ABI support, desugaring, Auth, PostgREST, and Realtime before the architecture is allowed to depend on this baseline.

## 3. Non-interference contract

### Shared behavior, not parallel behavior

- `account_settings.lock_timer_minutes` maps to `Preferences.triggerLockCount`.
- `usb_trigger_enabled` changes only the existing `Trigger.USB` bit and preserves every other trigger bit.
- Create `LocalSettingsApplier`; local UI, existing P2P `SettingsSyncManager`, and Supabase call it. It validates, writes preferences atomically, reschedules/cancels the existing lock job as needed, updates Android components, and requests service reconfiguration.
- Create `TimerCoordinator` around the existing `LockJobManager`; do not add a second destructive timer. It records restart-safe reporting metadata while preserving current semantics: screen-off/locked schedules, user-present cancels, Reset Timer restarts only an active locked timer, and an unlocked/inactive device remains inactive.
- Create one `ResetExecutor`/`DestructiveActionGate`. The only production call to the low-level wipe API must be inside this class. Refactor both current callers—`Utils.fire()` and `RemoteControlManager.executeLocalReset()`—through it. `LockJobService` continues through `Utils.fire()`.
- Supabase uses a new random installation UUID. Never reuse or change the existing P2P device identity, peer database, certificates, or pairing state.

### Foreground service lifecycle

- Add an idempotent `ACTION_RECONFIGURE` to the existing `ForegroundService`; track registered receiver/controller state and diff it safely.
- Reconfiguration independently starts/stops Lock receiver, USB receiver, P2P controller, and RemoteSyncCoordinator. Enabling/disabling one subsystem must not affect the others.
- Update `Utils.updateForegroundRequiredEnabled()` and `RestartReceiver.needsForeground` to use: existing Lock/USB requirement OR P2P enabled OR Remote Management enabled+enrolled.
- Call `startForeground()` before networking work. On destroy, unsubscribe Realtime, remove its channel, cancel the remote scope, then independently stop P2P/receivers.
- At `LOCKED_BOOT_COMPLETED`, start only direct-boot-safe existing behavior. Supabase credentials remain credential-protected; start remote sync after `BOOT_COMPLETED`/`USER_UNLOCKED`/app start.
- Implement foreground-service behavior by OS level: API 24–28 uses the two-argument `startForeground()`; API 29–33 declares/passes `connectedDevice` only while P2P is active and uses the ordinary two-argument call for remote-only operation; API 34+ declares `FOREGROUND_SERVICE_SPECIAL_USE`, `connectedDevice|specialUse`, and `android.app.PROPERTY_SPECIAL_USE_FGS_SUBTYPE="remote device protection and control"`, then passes the runtime type mask matching the active P2P/remote subsystems. Keep one clear ongoing notification. Do not label the Supabase socket as `connectedDevice` or use the time-limited `dataSync` type. Verify store/distribution declarations against the exact release target.

### Safe defaults and first synchronization

- Remote Management defaults OFF and does not start networking, change settings, or alter existing service decisions.
- Upgrade migration writes an explicit Debug Mode ON value before any destructive operation; enabling Remote Management for the first time locally forces Debug Mode ON before enrollment.
- Debug Mode defaults ON for every install; missing, corrupt, unreadable, or racing state is treated as ON. While ON, a dangerous command is never executed — it is logged, and a local notification states it was received but not executed in Debug Mode.
- First enrollment sends the device's current Lock Timer and USB Trigger to `claim_device_enrollment`. If account settings were never initialized, the RPC seeds them from that device. If the owner already set desired values, the device receives them. Enrollment must never silently overwrite an already initialized account.
- Disabling or revoking Remote Management stops cloud sync but leaves local settings, timer, Device Admin, and P2P unchanged.

## 4. Supabase schema contract

Use lowercase `snake_case`, `timestamptz`, named constraints, explicit foreign-key delete behavior, and no unbounded JSON command payload. Use `pgcrypto` only for random bytes/hashing. `public` is the exposed Data API schema; enrollment secrets and authorization helpers live in non-exposed `private`.

### `public.accounts`

- `id uuid primary key references auth.users(id) on delete cascade`
- `handle text not null`; trimmed length 3–32; regex `^[A-Za-z0-9][A-Za-z0-9_.-]{2,31}$`
- `created_at timestamptz not null default now()`
- unique index on `lower(handle)`

### `public.devices`

- `id uuid primary key default gen_random_uuid()`
- `account_id uuid not null references public.accounts(id) on delete cascade`
- `auth_user_id uuid null unique references auth.users(id) on delete set null`
- `installation_id uuid not null unique`
- `name text not null` with trimmed length 1–80
- `enrolled_at timestamptz not null default now()`
- `revoked_at timestamptz null`; check null or `>= enrolled_at`
- `created_at/updated_at timestamptz not null default now()`
- unique `(id, account_id)`
- check: an active row must have a non-null `auth_user_id`; a revoked historical row may remain after its Auth identity is deleted

### `private.device_enrollments`

- `id uuid primary key default gen_random_uuid()`
- `account_id uuid not null references public.accounts(id) on delete cascade`
- `token_hash bytea not null unique` (SHA-256 of a 256-bit token; plaintext is returned once)
- `expires_at timestamptz not null`; check `> created_at`
- `consumed_at timestamptz null`
- `consumed_by_device_id uuid null references public.devices(id) on delete set null`
- `revoked_at timestamptz null`
- `created_at timestamptz not null default now()`
- checks: consumed/revoked timestamps are null or `>= created_at`; consumed timestamp/device are either both null or both set; consumed and revoked states cannot both be set

### `public.account_settings`

- `account_id uuid primary key references public.accounts(id) on delete cascade`
- `revision bigint not null default 0 check (revision >= 0)`
- `lock_timer_minutes integer not null default 10080 check (between 1 and 525600)`
- `usb_trigger_enabled boolean not null default false`
- `initialized_at timestamptz null`
- `updated_by uuid null references auth.users(id) on delete set null`
- `updated_at timestamptz not null default now()`

### `public.device_status`

- `device_id uuid primary key`, `account_id uuid not null`
- composite FK `(device_id, account_id)` → `devices(id, account_id)` on delete cascade
- `applied_settings_revision bigint not null default 0 check (>= 0)`
- `actual_lock_timer_minutes integer not null check (between 1 and 2147483647)`
- `actual_usb_trigger_enabled boolean not null`
- `timer_remaining_seconds bigint not null check (>= 0)`
- `timer_running boolean not null`
- `debug_mode boolean not null`, `reset_supported boolean not null`, `remote_enabled boolean not null`
- `app_version text not null` length 1–64; `android_sdk smallint not null check (between 24 and 1000)`
- `last_error_code text null` max 64; `last_error_message text null` max 256
- `timer_sampled_at timestamptz not null`, `last_seen_at timestamptz not null`, `updated_at timestamptz not null`
- all three timestamps are assigned by the RPC/database, not trusted from the device

### `public.account_actions`

- `id uuid primary key default gen_random_uuid()`
- `account_id uuid not null references public.accounts(id) on delete cascade`
- `action_type text not null check in ('reset_timer','force_reset')`
- `idempotency_key uuid not null`; unique `(account_id, idempotency_key)`
- `created_by uuid null references auth.users(id) on delete set null`
- `created_at timestamptz not null default now()`, `expires_at timestamptz not null check (> created_at)`
- unique `(id, account_id)`

### `public.device_commands`

- `id uuid primary key default gen_random_uuid()`
- `action_id uuid not null`, `device_id uuid not null`, `account_id uuid not null`
- composite FK `(action_id, account_id)` → `account_actions(id, account_id)` on delete cascade
- composite FK `(device_id, account_id)` → `devices(id, account_id)` on delete cascade
- `command_type text not null check in ('reset_timer','force_reset')`
- `state text not null default 'queued'` checked against `queued, received, executing, applied, reset_initiated, debug_blocked, rejected, failed, expired`
- `created_at timestamptz not null default now()`, `expires_at timestamptz not null check (> created_at)`
- nullable `received_at`, `executing_at`, `finished_at timestamptz`
- `result_code text null` max 64
- unique `(action_id, device_id)` and unique `(id, account_id, device_id)`
- A private `before insert or update` consistency trigger rejects rows whose `account_id`, `command_type`, or `expires_at` differs from the referenced `account_actions` row. Test it directly; RPC-only correctness is not sufficient.

### `public.command_events`

- `id bigint generated always as identity primary key`
- `command_id uuid not null`, `device_id uuid not null`, `account_id uuid not null`
- composite FK `(command_id, account_id, device_id)` → `device_commands(id, account_id, device_id)` on delete cascade
- `event_type text not null` checked against the command states
- `result_code text null` max 64; `detail text null` max 256
- `created_at timestamptz not null default now()`
- unique `(command_id, event_type)` to make transitions/event insertion idempotent

### Required indexes

- `accounts_handle_lower_uidx` unique on `lower(handle)`.
- `devices_account_active_idx` on `(account_id, created_at desc)` where `revoked_at is null`.
- `device_enrollments_account_open_idx` on `(account_id, created_at desc)` where unused/unrevoked.
- `device_status_account_seen_idx` on `(account_id, last_seen_at desc)`.
- `account_actions_account_created_idx` on `(account_id, created_at desc)`.
- `device_commands_device_pending_idx` on `(device_id, created_at)` where state is `queued` or `received`.
- `device_commands_account_created_idx` on `(account_id, created_at desc)`.
- `command_events_command_created_idx` on `(command_id, created_at)`.
- `command_events_account_created_idx` on `(account_id, created_at desc)`.
- Run the Supabase missing-FK-index query after migrations and add any missing referencing-column index.

## 5. Exact RPC/state contract

Every RPC is `security definer set search_path = ''`, fully schema-qualifies every object, checks `(select auth.uid())`, validates every input, keeps transactions short, and receives an explicit `REVOKE EXECUTE FROM public, anon, authenticated` followed only by its required `GRANT EXECUTE TO authenticated`. Private authorization helpers are not directly executable by client roles.

### Owner RPCs

`initialize_owner_account(p_handle text) returns public.accounts`

- Reject anonymous users. Trim/validate handle. Atomically create the owner's account and uninitialized settings row. Idempotent only for the same Auth user.

`create_device_enrollment() returns (enrollment_id uuid, enrollment_token text, expires_at timestamptz)`

- Owner only. Generate `encode(gen_random_bytes(32),'hex')`; store only `digest(token,'sha256')`; expire after 10 minutes; revoke older unused owner tokens; return plaintext once.

`rename_device(p_device_id uuid, p_name text) returns public.devices`

- Owner only; verify ownership; trim/validate; server-stamp `updated_at`.

`revoke_device(p_device_id uuid) returns void`

- Owner only; lock device; server-stamp `revoked_at`; reject its queued/received commands with `device_revoked`; do not change an executing/terminal command. RLS access must disappear immediately.

`update_account_settings(p_expected_revision bigint, p_lock_timer_minutes integer, p_usb_trigger_enabled boolean) returns public.account_settings`

- Owner only. Validate 1–525600 minutes. One conditional update with matching revision; set initialized, increment once, return conflict on stale revision.

`create_account_action(p_action_type text, p_idempotency_key uuid) returns jsonb`

- Owner only; allowlist two types. In one short transaction insert action and one command for every active device, locking/ordering devices by ID consistently.
- Duplicate account/idempotency key returns the original action and creates nothing.
- Fixed TTL: Reset Timer 24 hours; Force Reset 10 minutes. Later-enrolled devices do not inherit old actions.
- Return `action_id, created_at, expires_at, device_count`.

`expire_account_commands() returns integer`

- Owner only. Transition only that owner's overdue queued/received commands to `expired` and append idempotent expiration events. The dashboard calls it before initial/refreshed reads so a permanently offline device is not displayed as queued after TTL.

### Device RPCs

`claim_device_enrollment(p_token text, p_installation_id uuid, p_device_name text, p_local_lock_timer_minutes integer, p_local_usb_trigger_enabled boolean) returns public.devices`

- Anonymous authenticated caller only; reject owner callers. Token must be 64 lowercase hex characters.
- Lock matching enrollment `for update`; reject consumed/revoked/expired; create device with `auth.uid()`; consume token atomically.
- If settings are uninitialized, seed them from validated local values and set revision 1. Otherwise leave them unchanged.
- A lost-response retry by the same auth UID/installation UUID returns the same device, not a duplicate.
- Lock the `account_settings` row `for update` before checking/seeding it so two simultaneous first claims cannot race.

`device_reconcile(p_device_id uuid, p_applied_settings_revision bigint, p_actual_lock_timer_minutes integer, p_actual_usb_trigger_enabled boolean, p_timer_remaining_seconds bigint, p_timer_running boolean, p_debug_mode boolean, p_reset_supported boolean, p_remote_enabled boolean, p_app_version text, p_android_sdk smallint, p_last_error_code text default null, p_last_error_message text default null) returns jsonb`

- Require caller to match an active device. Upsert only its status and database-stamp timer sample/last seen/update times.
- Lazily expire overdue queued/received commands and append expiration events.
- Return `server_time`, device identity, desired settings, and unexpired queued/received commands in creation order.
- Returning a command does not mark it received. Android first commits it to encrypted Room, then transitions it.

`device_transition_command(p_device_id uuid, p_command_id uuid, p_expected_state text, p_new_state text, p_result_code text default null, p_detail text default null) returns public.device_commands`

- Verify active device and ownership; lock row; validate TTL/type/transition; update state/timestamp and append exactly one event atomically.
- Legal transitions:
  - `queued → received | expired`
  - `received → executing | debug_blocked | rejected | failed | expired`
  - `executing → applied | reset_initiated | debug_blocked | failed`
- Reset Timer terminal states: `applied | rejected | failed | expired`.
- Force Reset terminal states: `reset_initiated | debug_blocked | rejected | failed | expired`.
- All terminal states are immutable. A duplicate/stale expected state returns a deterministic conflict and appends no event.

### Reset Timer execution order

1. Persist the command in encrypted Room, then transition `queued → received`.
2. Persist local `executing`, then transition `received → executing`.
3. Ask `TimerCoordinator` for current state. If locked/running, restart the existing LockJob deadline from now; if unlocked/inactive, keep it inactive and record that truthful result.
4. Persist the resulting timer state and transition `executing → applied`.
5. After a crash, an `executing` Reset Timer may safely rerun because the operation is idempotent; it must then finish `applied` or `failed`.

### Force Reset execution order

1. Reconcile and validate command/type/expiry/device.
2. Insert/update encrypted local journal as `received`; commit.
3. Server transition `queued → received`.
4. Re-read local Debug Mode. If blocked, transition `received → debug_blocked`; never invoke wipe.
5. Validate Device Admin/reset support.
6. Persist local `executing`; transition server `received → executing` and require success.
7. Re-read Debug Mode immediately before the destructive boundary.
8. If it became enabled, transition `executing → debug_blocked` and stop.
9. Transition server `executing → reset_initiated`, persist locally, flush logs/storage, then call `ResetExecutor` once.
10. Never automatically retry a command recorded `reset_initiated`. A crash between server recording and wipe may prevent reset; safety takes priority over duplicate wipe. The owner must issue a new action.

Startup recovery rules:

- A Force Reset found locally/server-side as `executing` but not `reset_initiated` is never resumed destructively. Transition it to `failed` with `interrupted_before_reset` when possible and require a new owner action.
- If the encrypted journal is unavailable/corrupt, fail closed: do not execute any returned `received`/`executing` Force Reset, surface `journal_unavailable`, and require local repair/re-enrollment.
- Drain pending acknowledgement/outbox work before acting on freshly reconciled commands. A locally terminal command is never re-executed merely because the server transition is still pending.

## 6. RLS, privileges, and Realtime

Enable and force RLS on every public table. Revoke all direct insert/update/delete from `anon` and `authenticated`; all writes use RPCs. Grant authenticated SELECT only where the following policies permit it:

| Table | Owner policy | Active device policy |
| --- | --- | --- |
| `accounts` | own row (`id = auth.uid()`) | none |
| `devices` | rows with own `account_id` | own active row by `auth_user_id` |
| `account_settings` | own row | bound account row |
| `device_status` | own account rows | none (RPC response is sufficient) |
| `account_actions` | own account rows | none |
| `device_commands` | own account rows | own device rows |
| `command_events` | own account rows | own command rows only if required |

- `private.device_enrollments` and private helpers have no Data API table grants/policies.
- Use `(select auth.uid())` in policies. Index all account/device ownership columns.
- `anon` receives no table access and no RPC execution. Anonymous Supabase Auth sessions assume `authenticated`; RPCs distinguish them using the verified JWT `is_anonymous` claim and account/device membership.
- Set default privileges so future public tables/functions are not automatically writable/executable by client roles.
- The public publishable key is allowed in website/APK; `service_role`, database credentials, enrollment plaintext tokens, and private keys are never shipped.

Add only `account_settings`, `devices`, `device_status`, and `device_commands` to `supabase_realtime`; check `pg_publication_tables` before adding, never drop/recreate the publication. Keep default primary-key replica identity. Do not publish accounts, enrollment records, actions, or events.

- Android filters settings by bound account ID and commands by device ID.
- Dashboard filters devices/status/commands by account ID.
- RLS is authoritative; subscription filters are only bandwidth optimization.
- On SUBSCRIBED, reconnect, auth refresh, service start, app start, network restoration, or channel error recovery, run a full authoritative reconciliation/refetch.

## 7. Supabase migrations and MCP procedure

Inspect existing migration history first, reserve five consecutive unused version identifiers, then create these repository files before any remote mutation (`<next_00N>` means those verified identifiers, not literal filenames):

```text
supabase/migrations/<next_001>_remote_schema.sql
supabase/migrations/<next_002>_remote_rpcs.sql
supabase/migrations/<next_003>_remote_rls_grants.sql
supabase/migrations/<next_004>_remote_realtime.sql
supabase/migrations/<next_005>_remote_maintenance.sql
supabase/tests/remote_schema_test.sql
supabase/tests/remote_rls_test.sql
supabase/tests/remote_rpc_test.sql
supabase/tests/remote_concurrency_test.sql
supabase/seed.sql
```

MCP execution steps:

1. Inspect the linked project through Supabase MCP and verify it is the intended client project (`Wasted Backend`) before mutation. If identity/ownership differs, stop.
2. Inspect existing schemas, extensions, migrations, Auth configuration, Realtime publication, and advisors. Do not overwrite unrelated objects.
3. Set `api.auto_expose_new_tables = false`. Enable email/password account signup and anonymous device identities; keep SMS disabled, email confirmation disabled unless working SMTP is later requested, anonymous sign-ins limited to 10/hour/IP, owner signup/sign-in limited to 10 requests/5 minutes/IP, refresh-token rotation enabled, minimum password length 12 with mixed character classes, and the final Site URL/redirect allowlist. Because no production SMTP was requested, do not add confirmation/recovery email UI or silently assume delivery. This does not grant anonymous database access. Use Supabase MCP for every available project/Auth change and reread the effective configuration through MCP afterward. If MCP cannot perform or verify a required setting, stop and report that exact blocker; never continue from an assumed dashboard value.
4. Write migrations locally with `apply_patch`; migrations are forward-only, transactional where supported, and idempotent only where Supabase replays require it.
5. Apply each migration in order through Supabase MCP. Never edit an applied migration; corrections use a new timestamped migration.
6. Run schema/check/FK/index tests, then two-owner/two-device RLS tests, then RPC/idempotency/transition/expiry/revocation/concurrency tests.
7. Verify Realtime delivers only rows each test identity can SELECT and that reconnect refetch closes an intentionally missed event.
8. Run Supabase security and performance advisors. Fix every relevant finding in a new migration.
9. Generate current database types for the website and commit them.
10. Recreate a clean local database entirely from migrations/seed and rerun all tests. Compare local/remote migration history and schema drift.

The maintenance migration enables `pg_cron` and schedules one daily, short SQL cleanup. It deletes anonymous `auth.users` identities older than 24 hours that never bound to a device, plus identities belonging only to devices revoked for more than 30 days; `devices.auth_user_id on delete set null` preserves device/audit history. Give the job a stable name, unschedule that name before rescheduling, test its predicate with fixtures, and never delete active identities or application audit rows.

Mandatory fixtures: Owner A/B, devices A1/A2/B1/B2, an unclaimed anonymous identity, and a revoked device. Prove cross-owner/cross-device denial, no rows for unclaimed/revoked identities, no direct command/settings/status writes, one winner for concurrent first-enrollment settings initialization and revision updates, action/command consistency-trigger rejection, action/transition idempotency, both device-lazy and owner-triggered expiry, actor/Auth-user deletion behavior, server timestamps, restricted Realtime visibility, and clean re-enrollment after revocation.

## 8. Android implementation contract

### Required files/boundaries

```text
app/src/main/java/me/lucky/wasted/
  admin/ResetExecutor.kt                 central destructive gate/port
  settings/LocalSettingsApplier.kt       shared local/P2P/Supabase application
  trigger/lock/TimerCoordinator.kt       existing JobScheduler adapter/status
  remote/domain/RemoteModels.kt
  remote/domain/RemoteSyncCoordinator.kt single-flight orchestration only
  remote/data/RemoteCredentialStore.kt   Tink/Keystore session + install UUID
  remote/data/RemoteDatabase.kt          separate SQLCipher Room database
  remote/data/RemoteCommandDao.kt
  remote/data/SupabaseRemoteRepository.kt Auth/RPC/PostgREST adapter
  remote/data/RemoteRealtimeClient.kt    channel lifecycle/invalidation only
  remote/work/RemoteRecoveryWorker.kt    eventual recovery only
  remote/ui/RemoteManagementFragment.kt
```

- Use constructor interfaces/fakes around network, clock, timer, settings, notification, and reset operations. Activities/fragments never call Supabase or `DevicePolicyManager` directly.
- Do not add a second DI framework solely for this feature; use the project's simplest explicit composition root in `Application`/service.

### Secure local state

- `RemoteCredentialStore` is credential-protected and Tink/Keystore-backed. Store installation UUID, remote-enabled/enrolled state, device/account IDs, and the custom supabase-kt `SessionManager` session. Never copy tokens to direct-boot preferences or Android backup.
- Keep `remoteNotificationsEnabled` as a device-local preference, default OFF for upgrades. It controls only user-facing remote-event notifications; it never controls command receipt, acknowledgements, logging, or the persistent foreground-service notification required by Android.
- Configure supabase-kt Auth so Android background lifecycle callbacks do not clear the service session. The coordinator explicitly loads, refreshes, observes, and deletes sessions; a refresh failure pauses sync/retries but never disables local protection.
- Revocation or an irrecoverably lost device session never reactivates/rebinds the old device row. An explicit local **Reset Remote Enrollment** action stops sync, clears only the Supabase session and encrypted remote journal/outbox, rotates the installation UUID, creates a new anonymous Auth identity, and requires a fresh owner enrollment token. Preserve the revoked server row and audit history. Never run this automatically after an auth/network error.
- New `RemoteDatabase` uses SQLCipher and a random database passphrase wrapped by Android Keystore/Tink. Do not place remote state in the existing plaintext P2P Room database.
- Room entities: `remote_command_journal(command_id PK, type, state, received_at, executing_at, terminal_at)` and `remote_outbox(id PK, kind, command_id nullable, payload, created_at, attempt_count, next_attempt_at)`. Unique command IDs prevent replay; outbox retries acknowledgements/status without retrying destructive execution.
- Store validated Supabase URL, publishable key, and `remoteWebsiteUrl` in encrypted preferences with no client defaults embedded in the APK. Open the website through an external browser intent. Production accepts HTTPS only; debug builds may additionally allow loopback HTTP for local testing. Reject malformed, credential-bearing, privileged-key, or non-web values.

### Sync/retry constants

- One mutex/single-flight reconciliation; coalesce duplicate signals.
- Foreground heartbeat/reconcile every 60 seconds while enabled, enrolled, unlocked, and connected.
- Dashboard: `recently connected` at ≤150 seconds since server `last_seen_at`; otherwise `offline/stale`, always show exact last contact.
- Realtime reconnect: exponential 1, 2, 4, 8…60 seconds, ±20% jitter; reset after stable subscription; refresh auth/recreate channel when required.
- WorkManager `RemoteRecoveryWorker`: unique network-constrained one-time work after failures plus unique 15-minute periodic reconciliation (5-minute flex). It is a safety net, never described as immediate delivery.
- Retry only network/timeout/HTTP 429/5xx with server delay or bounded exponential backoff. Authentication, RLS, validation, expiry, and illegal transition failures stop and surface a sanitized error.
- Emit local notifications only for meaningful state changes or user-requested sync. Deduplicate by command/correlation ID and apply a cooldown to repeated success/status notices; never notify on each heartbeat.

### Debug Mode invariant

- Existing installs get an explicit migrated value before any destructive operation. First remote enablement forces ON locally.
- `ResetExecutor` re-reads the encrypted preference at the final boundary. ON/missing/corrupt/read error means `debug_blocked` and zero low-level wipe calls.
- Website and remote RPCs cannot modify it. Turning OFF requires a local danger dialog and explicit confirmation.
- Static check: repository search must show no production `DeviceAdminManager.wipeData()` invocation outside `ResetExecutor`.
- Unit/instrumentation fakes assert zero destructive calls for local trigger, LockJobService, P2P immediate/confirmed reset, Supabase command, duplicate, missing/corrupt preference, and toggle race.

## 9. Dashboard implementation contract

```text
web/
  index.html
  config.example.js        # project URL + publishable key only
  src/main.js
  src/supabase-client.js
  src/auth.js
  src/enrollment.js
  src/devices.js
  src/settings.js
  src/commands.js
  src/timers.js
  src/ui.js
  styles/main.css
  tests/
  package.json
  package-lock.json
  dist/                    # generated copy-deployable output
```

- Use no UI framework. Bundle pinned supabase-js and source modules; production has no CDN/runtime package dependency.
- `config.js` contains only Supabase URL/publishable key and documented website metadata. Never include service role/database password.
- Auth screens: explicit email/password **Sign In** and **Create Account**, understandable errors, and sign-out/session clear. Create Account calls Supabase Auth signup, then `initialize_owner_account(handle)`; handle is a display/account identifier, never the password identity. Do not silently create after failed Sign In: Supabase does not safely distinguish “unknown account” from “wrong password,” and auto-creation would turn password typos into unwanted accounts. This fulfills the client's “sign into or create an account” flow without account enumeration. Do not ship confirmation/recovery email UI unless working email delivery is later requested and verified.
- Enrollment: owner creates a 10-minute token/QR; Android claims it. Never expose stored token hashes or owner credentials.
- Device cards show name/ID, actual vs desired settings/revision, active/inactive timer, locally extrapolated remaining time, Debug Mode, reset support, last seen, connection freshness, app/OS, and latest command result.
- Reset Timer and Force Reset show affected device count and confirmations. Force Reset requires danger styling, explicit typed confirmation, one idempotency UUID per deliberate submission, and double-submit prevention.
- Realtime only invalidates/refetches. Reconnect performs a full refresh. Render truthful per-device states; never report `completed` after a wipe unless evidence exists.
- Meet keyboard/focus, semantic label, contrast, reduced-motion, responsive, loading/empty/error/offline requirements. Footer shows only actual product/version/support/privacy data supplied by the project.
- Build with a supported Node LTS, run unit/browser/accessibility tests, and copy only `dist/` plus environment-specific `config.js` to HTTPS hosting. Configure Supabase Site URL/allowed redirects for the final host.

## 10. Ordered implementation phases

### Phase 1 — API 24 foundation, shared safety, and regression baseline

- [x] Baseline capture done. `./gradlew clean build` green (2 pre-existing lint errors fixed to unblock).
  - Evidence: `evidence/phase1/`. Tests currently placeholders; interactive local/P2P flow logs run at the gate.
- [x] Fail-closed config boundary added (`RemoteConfigStore`, `RemoteConfigValidator`): encrypted prefs, defaults unconfigured/OFF, partial/corrupt reads fail closed, https-only (+debug loopback), secret key formats rejected.
  - 22 unit tests green + lint clean (`evidence/phase1/config-boundary-tests.log`); no Supabase client or caller exists — `canStartRemoteWork()` gates all future work.
- [ ] Apply Android 7/toolchain/dependency baseline and complete API 24 Supabase/Realtime/SQLCipher/desugaring spike.
- [ ] Add migrated Debug Mode, `ResetExecutor`, and fake reset port; route `Utils.fire()` and P2P reset through it.
- [ ] Extract `LocalSettingsApplier` and `TimerCoordinator`; switch existing local/P2P code to them before adding Supabase.
- [ ] Add idempotent ForegroundService `ACTION_RECONFIGURE` and independent subsystem state tracking.
- [ ] Add secure credential store and encrypted RemoteDatabase/journal/outbox, but no remote behavior yet.
- [ ] Gate: Android 7 build/install; all existing triggers, timer schedule/cancel, Device Admin tiers, P2P pairing/TLS/settings/reset, Shizuku, encrypted preference migration, foreground notification, reboot/package replacement pass. Debug Mode blocks every wipe path with zero calls.

### Phase 2 — Supabase core networking and durable synchronization

- [ ] Create/apply/test migrations and Auth/Realtime configuration through the exact MCP procedure in §7.
- [ ] Implement owner/device enrollment and generated models/types.
- [ ] Implement Supabase repository, custom session persistence, Realtime lifecycle, reconcile/transition RPC mapping, Room journal/outbox, retry classification, and secret-safe logs.
- [ ] Integrate RemoteSyncCoordinator into the existing service and reconfigure/boot/unlock/network/auth lifecycle.
- [ ] Implement account revision sync through LocalSettingsApplier, timer/status reporting through TimerCoordinator, Reset Timer idempotency, and Force Reset execution order.
- [ ] Implement WorkManager recovery without treating it as immediate delivery.
- [ ] Gate: all schema/RLS/RPC tests pass; two accounts/four devices cannot cross access; settings/commands survive missed Realtime, socket drop, process/service restart, network loss, auth refresh, and reboot. Existing P2P/local tests still pass.

### Phase 3 — Complete Android and website UI/control

- [ ] Build Android Remote Management screen with Supabase URL/publishable-key/website-URL Save/Test/Enable controls, local Debug toggle/confirmation, enrollment claim/reset-enrollment, connection/last-sync/manual-sync, name, Notifications toggle, deduplicated event notifications, errors, and website-open action.
- [ ] Build static dashboard files/flows from §9, including diagnostics, confirmations, accessibility, footer, and bundled production output.
- [ ] Add optional local notifications for remote setting change, Reset Timer, Force Reset, debug block, sync success, and processing failure.
- [ ] Update README with configuration, Supabase migrations/MCP, static deployment, enrollment, Debug Mode, limitations, troubleshooting, and rollback.
- [ ] Gate: Create Account, Sign In, account isolation, first setup, multiple devices, simultaneous first enrollment, initialized settings, conflict revision, timers, commands, revoke/re-enroll, offline/reconnect, notification deduplication, URL validation, responsive and keyboard/screen-reader flows pass end to end. Existing app navigation/features remain unchanged.

### Phase 4 — Security, real-device reliability, rollout

- [ ] Run Android unit/instrumentation suites for validation, settings/timer behavior, service reconfigure, concurrency, retry, journal/outbox, Debug Mode, and log redaction.
- [ ] Run Supabase clean migration, pgTAP/RLS/RPC/concurrency/Realtime tests and security/performance advisors.
- [ ] Run web unit/browser/accessibility/CSP/session/account-isolation tests and dependency/secret scans.
- [ ] Real-device matrix: Android 7, 13, and 15 minimum; foreground/background/screen-off/Doze/OEM saver/offline/socket loss/process/service restart/reboot/user unlock/force-stop.
- [ ] Run ≥16-hour spare-phone soak with Debug Mode ON. Repeatedly send settings, Reset Timer, and Force Reset; archive dashboard timestamps, DB events, and logcat; prove every Force Reset is debug-blocked and low-level wipe count is zero.
- [ ] Record p50/p95 command latency, reconnect time, missed/delayed scenarios, battery impact, and foreground-notification behavior. Client accepts measured reliability before release.
- [ ] Verify actual §17 Free-plan headroom in Supabase Usage/Realtime reports and prove projected monthly usage remains below every internal threshold.
- [ ] Rebuild a fresh Supabase project from tracked migrations/config documentation, verify zero schema drift, and prove the same release APK can be configured and enrolled against it.
- [ ] Only with separate explicit approval, locally disable Debug Mode on an empty sacrificial phone and perform one real wipe E2E test.
- [ ] Gate: no security/advisor blocker, all regression/compatibility/soak evidence passes, docs match implementation, and release/rollback rehearsal succeeds.

## 11. Regression matrix (must remain green)

- Master enable/disable and admin removal.
- Panic Kit, tile, shortcut, broadcast, notification, lock, USB, and application triggers.
- LockJob schedule/cancel/reboot and timer reporting; local settings changed while service is already running.
- Device Admin reset behavior for each Android tier and Shizuku/manual wipe paths.
- P2P discovery, pairing, certificates/TLS, queue/retry, settings sync, reset confirmation, and device identity.
- Foreground service when Lock/USB only, P2P only, remote only, combinations, and none.
- Direct boot/user unlock/package replacement and encrypted preference migration/corruption.
- Remote disabled/unconfigured/offline: zero network dependency and unchanged local behavior.
- Remote/P2P independent toggling: stopping one never stops or reconfigures the other incorrectly.

## 12. Rollout and rollback

1. Apply additive database migrations; old APK ignores new tables.
2. Release test APK with Remote Management OFF and Debug Mode ON for enrollment; verify existing behavior first.
3. Deploy static dashboard and enroll only spare devices.
4. Complete soak and client reliability acceptance.
5. Enable production enrollments; real wipe remains locally gated.

Rollback:

- Disable Remote Management locally to stop Realtime without changing local/P2P behavior.
- Roll back website by replacing `dist/` with the previous artifact; database APIs remain backward compatible.
- Roll back APK only to a version compatible with the additive schema.
- Never delete/rename columns or relax RLS in the initial release. Database corrections use forward-only compensating migrations; preserve command/audit evidence.

## 13. Acceptance checklist

- [ ] Static website is copy-deployable and contains no privileged secret.
- [ ] Owner/device enrollment uses separate identities; revoked/unclaimed/cross-account access is denied by tested RLS.
- [ ] Multiple devices show accurate settings, timer, Debug Mode, reset support, status, and last contact.
- [ ] Lock Timer/USB changes use existing app behavior and converge after reconnect without touching other settings.
- [ ] Reset Timer is once-only/idempotent and preserves current lock/unlock semantics.
- [ ] Force Reset has durable unique commands, legal transitions, expiry, truthful states, and no automatic destructive replay.
- [ ] Debug Mode is local-only, fail-closed, and verified across every reset path.
- [ ] Realtime is prompt while connected; durable reconcile closes missed-event gaps.
- [ ] Existing Device Admin, local triggers, P2P, Shizuku, timer, and offline behavior pass the full regression matrix.
- [ ] Android 7/13/15 plus 16-hour spare-phone evidence is archived and accepted.
- [ ] Supabase MCP migrations, tests, advisors, generated types, README, deployment, and rollback are complete.
- [ ] The single public APK contains no client configuration or privileged secret; its default/unconfigured state makes zero Supabase requests.
- [ ] Free-tier capacity report and quota-threshold evidence are archived; the implementation remains within the Free plan.

## 14. External inputs that do not block Phase 1

These are needed only at their release step:

1. Client Supabase organization/project access must be available through an invitation; the agent verifies the already linked `Wasted Backend` project via MCP before applying migrations.
2. Final static website URL is needed for the client setup instructions and Supabase Auth redirect allowlist; it is not embedded in the public APK.
3. Client accepts measured background reliability after the Debug Mode soak.

An implementation agent can start at Phase 1 without another architecture pass. It must not claim the feature complete until all four phase gates and the acceptance checklist are evidenced.

## 15. Single public APK and Supabase configuration boundary

Ship the normal GitHub release of the existing app. Release notes must state that Remote Management is an advanced configured feature, defaults OFF, and requires a compatible Supabase project; ordinary users should leave it unconfigured.

- Remote Management defaults OFF with empty configuration. In Settings, provide inputs for Supabase project HTTPS URL, Supabase publishable key, and remote website HTTPS URL, plus explicit Save/Test and Enable actions.
- Validate scheme/host/length, reject embedded credentials and privileged key formats, store values encrypted and excluded from Android backup, and redact them from logs/crash reports. Never accept or store `service_role`, database password, management token, or signing secret.
- Saving configuration does not start networking. Enabling requires successful anonymous device authentication and a valid one-time enrollment token from an authenticated owner. Invalid, incomplete, cleared, or corrupt configuration fails closed and leaves all existing Wasted behavior unchanged.
- A fresh/default installation must create no Supabase client, session, database, worker, WebSocket, or HTTP request. Disabling Remote Management cancels all remote work and clears the active session while leaving local/P2P behavior unchanged; configuration is cleared only through a separate confirmed action.
- The client enters the project URL/publishable key locally. Normal downloaders do not receive client configuration from GitHub. They may point the open-source app at their own compatible Supabase deployment, but the project does not provide a shared public backend.
- The Supabase publishable key is not a secret and cannot technically prevent somebody who learns it from sending API requests. Security must remain correct even then: owner/device signup rate limits, strong passwords, unbound anonymous-user cleanup, forced RLS, denied direct writes, one-time device enrollment, RPC authorization, and cross-account/device tests are mandatory. An unbound or wrong-account caller must receive no protected data and perform no protected mutation.
- Add instrumentation tests for default/unconfigured, malformed configuration, known publishable-key access without enrollment, revoked device, wrong account, disable/clear, upgrade, and reinstall paths.

## 16. Supabase infrastructure as code and migration to another account

Git is the source of truth for reproducible structure and configuration—not for production secrets or client data.

Commit:

- `supabase/config.toml` with local Auth, Realtime, database, port, seed, and rate-limit settings mirroring production where the CLI supports them.
- Every ordered SQL migration from §7, including extensions, schemas, tables, constraints, indexes, triggers, functions/RPCs, grants, RLS policies, Realtime publication changes, and the named maintenance job.
- `supabase/seed.sql` containing synthetic development/test identities and rows only; make it safe to publish and repeat.
- `supabase/tests/*.sql`, generated website database types, `config.example.js`, an environment-variable example containing names/placeholders only, and `supabase/README.md` with bootstrap, verification, project recreation, and rollback commands.
- A non-secret hosted-project manifest in `supabase/README.md`: Auth providers, public/anonymous signup switches, rate limits, redirect URLs, CAPTCHA decision, Realtime tables, extensions, and any setting Supabase cannot represent in SQL/config. Record expected values and how MCP verifies each one.

Never commit:

- Supabase access/management tokens, database password/URL, `service_role` or secret API keys, JWT signing keys, Android signing material, plaintext enrollment tokens, `.env` files, linked-project metadata, real email addresses, device/status/command data, or production database dumps.
- The client project URL/publishable key in tracked Android or website source. Although designed to be public at runtime, keeping client-specific values out of Git prevents the public release from accidentally targeting the client tenant.

Recreate on a new Supabase account/project:

1. Create the empty target project and link/verify its identity through Supabase MCP.
2. Apply the repository migrations in order through MCP; do not use a dashboard schema editor.
3. Apply the documented non-SQL Auth/rate-limit/redirect configuration and verify it through MCP/config export.
4. Run a clean migration reset and all schema/RLS/RPC/concurrency tests; run security/performance advisors and compare migration history/schema drift.
5. Deploy the static dashboard with the target publishable configuration; create the first owner through the specified Create Account flow and verify account initialization/RLS.
6. Enter the target configuration in the existing release APK and enroll devices. Git recreates the backend structure, not live Auth users, sessions, or client data.

Before each release, `supabase db diff --linked` (or the equivalent MCP schema comparison) must be empty after migrations, generated types must match the deployed schema, and a new local database must succeed from migrations plus synthetic seed alone. Applied migrations are immutable; corrections are forward-only.

## 17. Supabase Free-plan capacity and operating guardrails

The Free plan is sufficient for initial development and a small single-client deployment, but it is not an availability guarantee. Current included limits are 500 MB database size, 5 GB egress, 50,000 monthly active users, 2 million Realtime messages/month, and 200 peak Realtime connections. Free projects can be paused after low activity and do not include downloadable automatic backups/PITR.

Capacity model for the planned 60-second status heartbeat:

- One device performs at most 43,200 status upserts in a 30-day month. The row is overwritten, so this does not create 43,200 retained rows.
- A Postgres change counts once for each listening Realtime client. With ten devices and one dashboard continuously open, status delivery is approximately 432,000 messages/month; two continuously open dashboards make it approximately 864,000, before infrequent settings/command events.
- Use `device_count × 43,200 × concurrently_listening_dashboards` as the conservative monthly status-message estimate. Treat 1 million messages, 160 connections, 350 MB database size, or 3.5 GB egress as internal review thresholds rather than waiting for the hard Free-plan limits.
- Devices subscribe only to their account settings and own commands; they do not subscribe to every device status. Dashboards subscribe only while open. Keep the single-row status upsert, compact columns, scoped filters, indexed RLS predicates, refetch coalescing, and notification deduplication already specified.

Operational requirements:

- Record the expected device/dashboard count before client rollout and check Supabase Usage plus Realtime reports weekly during the soak and monthly afterward.
- Alert/document action at 70%, 85%, and 95% of any quota. Free-plan quota excess can lead to restrictions; do not promise unlimited free operation.
- Keep command/event retention measurable. Do not silently delete audit evidence; define an approved retention/export policy before database size reaches the internal threshold.
- Active one-minute device traffic should normally prevent inactivity pausing, but that is not an SLA. This implementation must stay within the Free plan: if forecasts or soak results reach an internal threshold, optimize unnecessary dashboard subscriptions/refetches and status writes while preserving the specified behavior, then repeat the capacity gate before release.
