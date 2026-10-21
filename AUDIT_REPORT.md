# Wasted Remote Management — Production Audit

**Audit date:** 2026-10-21

**Source reviewed:** `6ba8bcc8a524259bd8fa8ce45767c5e8c18f0383` with staged `AUDIT_PROMPT.md` and `AUDIT_CONTEXT.md`

**Profile:** Standard, repository-wide, read-only source audit

**Verdict:** **Not ready for production release.** The architecture is credible and the current SQL shows strong tenant isolation, enrollment, and destructive-action controls. No confirmed Blocker/High authorization or wipe-bypass vulnerability was found. Production readiness is blocked by incomplete runtime/deployment verification and two Medium findings: an inadequate post-install database verifier and a revocation state-machine gap. Dashboard response headers and release signing also need closure before publication.

The implementing context reports successful builds/tests and linked-project checks, but this audit did not rerun them. The repository itself lists fresh-project, upgrade, emulator/device, soak, browser/a11y, capacity, and destructive-boundary gates as open (`docs/backend/verification.md:79-86`). Treat implementation as substantially complete but production proof as incomplete.

## Executive summary

### Strong controls verified in source

- All seven public remote tables enable and force RLS; client roles receive select-only table access, while writes use explicitly granted SECURITY DEFINER RPCs (`supabase/migrations/20261018133359_remote_rls_grants.sql:7-22,85-109`; `supabase/migrations/20261018133312_remote_rpcs.sql:718-746`).
- Owner and anonymous-device identities are distinguished, and device RPCs bind `auth.uid()` to one active device (`supabase/migrations/20261018133312_remote_rpcs.sql:17-61`).
- Enrollment tokens are random, hashed, single-use, row-locked, and expire after ten minutes (`supabase/migrations/20261018133312_remote_rpcs.sql:111-135,380-487`).
- Debug Mode fails closed at the final wipe boundary and is re-read twice; only `ResetExecutor` delegates to `wipeData()` (`app/src/main/java/me/lucky/wasted/admin/ResetExecutor.kt:26-82`).
- Debug Mode OFF expires queued/received Force Reset commands before disabling the guard (`supabase/migrations/20261020131724_remote_debug_mode_commands.sql:91-145`).
- The dashboard renders server/user values with `textContent`; no `innerHTML`, `eval`, or equivalent HTML sink was found (`web/src/main.js:194-260,499-507`; `web/src/ui.js:5-17`).
- Release manifest coverage is complete for the nine migrations, and the checked-in 3.0.0 setup/verify SHA-256 values match `manifest.json` (`supabase/releases.json:1-20`; `supabase/releases/3.0.0/manifest.json:1-7`).

### Top risks

1. `verify.sql` can report all PASS while FORCE RLS, grants, RPC properties, policies, or publication scope are unsafe.
2. Revoking a device during `executing` preserves the row but prevents that device from ever terminalizing it.
3. The recommended single-file hosting path does not establish anti-framing headers; actual deployment headers need validation.
4. `assembleRelease` can succeed without release signing configuration.
5. The documented Auth rate limits are contradictory and actual project settings were not verified.

## Requirements matrix

| Client requirement | Status | Evidence and gap |
| --- | --- | --- |
| App-configured website URL; open from app (`archive/wasted update.txt:15-19`) | Done | HTTPS URL is validated, saved, and opened with `ACTION_VIEW` (`app/src/main/java/me/lucky/wasted/remote/ui/RemoteManagementFragment.kt:153-175,212-223`). |
| Sign in, account identity, password; auto-create if feasible (`:23-35`) | Done + Deviation | Explicit Sign In/Create Account with email, password, and handle exists (`web/src/auth.js:3-44,57-74`). Only auto-creation deviates: failed sign-in does not create an account (`docs/backend/decisions.md:64-70`). |
| Device ID/name/settings/timer/status; multiple devices (`:39-51`) | Done | Random encrypted installation ID and multi-device schema/enrollment exist (`app/src/main/java/me/lucky/wasted/remote/data/RemoteCredentialStore.kt:36-48`; `docs/backend/database.md:9-21`). Runtime enrollment remains unverified. |
| Lock Timer, USB Trigger, Reset Timer, Force Reset for all devices (`:55-68`) | Done | Account settings and actions fan out to active devices (`docs/backend/remote-protocol.md:39-46,103-108`; `web/src/main.js:168-177`). |
| Timer display, reporting, all-device timer reset (`:72-85`) | Done | Reconcile reports timer samples; dashboard extrapolates locally (`app/src/main/java/me/lucky/wasted/remote/domain/RemoteModels.kt:207-221`; `web/src/timers.js:14-29`). Timing accuracy is unverified on devices. |
| Force Reset sent/received/completed/offline/debug status (`:89-103`) | Partial | Durable states include queued, received, executing, reset-initialized, debug-blocked, rejected, failed, and expired (`RemoteModels.kt:166-177`). There is no post-wipe “completed” acknowledgement; `reset_initiated` is deliberately written before the destructive call (`RemoteCommandProcessor.kt:285-307`). Offline is inferred from last contact, not a command state. |
| Device status overview (`:107-121`) | Done | UI shows ID/name/contact/timer/actual-vs-desired settings/debug/reset support/app/OS/last command (`web/src/main.js:194-260`). |
| Debug Mode receives/tests commands but blocks wipe (`:125-139`) | Done + Extra | Local fail-closed guard is present; remote per-device ON/OFF is additional scope (`app/src/main/java/me/lucky/wasted/admin/ResetExecutor.kt:46-82`; `web/src/main.js:320-370`). |
| Optional event notifications (`:143-155`) | Partial/Deviation | Meaningful events are notified, but routine heartbeat success is intentionally silent; manual-sync success remains (`docs/architecture.md:94-99`; `docs/backend/decisions.md:81-86`). |
| Offline operation/reconnect/sync (`:159-171`) | Done, unverified | Design preserves local settings/timers and reconciles durable state on reconnect (`docs/architecture.md:86-92`; `docs/backend/remote-protocol.md:110-128`). Device/Doze/reboot testing remains open. |
| Lightweight, portable, independently hosted site (`:175-189`) | Done/Deviation | App exports one self-contained HTML file (`docs/backend/hosting.md:1-29`). Configuration is regenerated in-app rather than manually edited at runtime (`docs/backend/decisions.md:14-22`). |
| Two-way sync, acknowledgements, offline commands (`:193-214`) | Done, unverified | Reconcile plus durable command transitions and TTLs are implemented (`docs/backend/remote-protocol.md:6-60,110-128`). Real-device latency/recovery is open. |
| Password/HTTPS/device credential/account binding/validation/no public secrets (`:218-231`) | Done in source; deployment unverified | HTTPS-only config, Supabase Auth, unique anonymous device identity, RLS/RPC checks, and publishable-key-only dashboard are present (`RemoteModels.kt:67-117`; `docs/backend/security.md:17-38`). Live Auth/RLS/header settings were not observed. |
| First-time, remote, and offline flows (`:235-265`) | Done in design; unverified E2E | Documented at `docs/backend/setup.md:34-59`; fresh-project and device execution are still open gates. |

## Findings

### Blocker / High

No confirmed Blocker or High source vulnerability was found. Release readiness is nevertheless blocked by the unverified gates listed under Verification Status.

### Medium

#### M1. Post-install verifier can pass a materially insecure database

**Evidence:** `supabase/verify.sql:3-40` checks table names, RLS enabled (not forced), two RPC names, presence of four intended publication rows, and a cron job. It does not validate `relforcerowsecurity`, policies, direct/default grants, PUBLIC function execution, RPC signatures, SECURITY DEFINER/search path, exact publication membership, or schema version. Yet the user runbook says every PASS verifies setup (`docs/backend/updates.md:13-15`).

**Impact:** An operator can receive a green result for a drifted deployment that violates the documented security boundary. The deeper SQL suites cover more behavior but are not a substitute for a production-safe verifier and also miss the PUBLIC default-function ACL issue.

**Recommendation:** Expand `verify.sql` to check exact catalog invariants and fail closed. Validate FORCE RLS, exact grants/policies, RPC `regprocedure` signatures/owners/`prosecdef`/empty search path/ACLs, private-schema denial, exact Realtime set, and release/schema version. Require the full SQL suites in the release gate.

#### M2. Device revocation can strand an `executing` command permanently

**Evidence:** `revoke_device` terminalizes only queued/received commands and explicitly preserves executing rows (`supabase/migrations/20261018133312_remote_rpcs.sql:167-205`). Subsequent transitions require an active, unrevoked device (`:39-61,630-648`), while expiry handles only queued/received rows. Existing revocation tests do not cover executing commands (`supabase/tests/remote_rpc_test.sql:762-829`).

**Impact:** Dashboard and audit history can indefinitely show an unresolved destructive action. Operators cannot tell whether execution crossed the irreversible boundary.

**Recommendation:** Define and atomically record revocation semantics for every nonterminal state. Prefer a distinct terminal result such as `device_revoked_during_execution`/`outcome_unknown` where execution may already be irreversible; add revoke/transition race tests.

### Low

#### L1. Release assembly does not fail closed when signing is absent

**Evidence:** Signing configuration and assignment are conditional on `keystore.properties` existing (`app/build.gradle:8-12,28-45`). The documented gate checks the certificate only after building (`docs/backend/verification.md:7-15`; `docs/backend/release-checklist.md:21-32`).

**Impact:** Automation can produce an unsigned “release” artifact and advance it into later steps, risking failed distribution or publication of the wrong artifact.

**Recommendation:** Add an explicit production/publish task that fails before assembly unless signing inputs exist, then verify the expected certificate with `apksigner`. Keep any unsigned variant explicitly named and excluded from publishing.

#### L2. Account-action idempotency keys are not bound to operation type

`create_account_action` returns any existing row for `(account_id, idempotency_key)` without checking the requested action type (`supabase/migrations/20261018133312_remote_rpcs.sql:252-331`). A reset-timer/force-reset or account/debug collision can report success for the older action and silently skip the requested command. This is account-scoped correctness, not privilege escalation. Match `set_device_debug_mode` behavior: reject mismatched type/scope in both normal and unique-violation paths and add cross-RPC collision tests.

#### L3. Future-function default ACL does not revoke PostgreSQL `PUBLIC`

The default privilege migration revokes future function execution from `anon, authenticated` but not `PUBLIC` (`supabase/migrations/20261018133359_remote_rls_grants.sql:102-109`). Current RPCs explicitly revoke PUBLIC and are protected (`supabase/migrations/20261018133312_remote_rpcs.sql:720-746`; `20261020131724_remote_debug_mode_commands.sql:258-261`). A future missed revoke could expose a function because PostgreSQL grants function execution to PUBLIC by default. Revoke future function execution from PUBLIC and test effective privileges, not ACL text. This aligns with Supabase guidance to narrow function execution and pin SECURITY DEFINER search paths ([Supabase database functions](https://supabase.com/docs/guides/database/functions)).

#### L4. Enrollment token remains in the DOM after expiry/sign-out

The dashboard inserts the token into the DOM and clipboard (`web/src/main.js:444-464`); expiry only stops the timer and sign-out does not clear the token (`:471-496`). Backend single-use and ten-minute expiry limit impact. Clear/hide it on expiry, auth loss, sign-out, and replacement; warn that clipboard content may persist.

#### L5. Trusted optional-link configuration accepts unsafe schemes

`applyOptionalLink` assigns config values directly to `href` (`web/src/main.js:83-91`). The app-generated dashboard currently sets privacy/support URLs empty (`web/build-lib.mjs:20-29`), so the shipped path is not exposed, but manually configured builds could accept `javascript:`/`data:`. Parse URLs and allow only documented schemes, normally HTTPS.

#### L6. Account creation can leave a partial Auth user

Supabase sign-up occurs before `initialize_owner_account`; an RPC failure leaves a valid Auth user without the application account row (`web/src/auth.js:63-74`). Add retry/recovery UX that detects and initializes an authenticated but uninitialized owner, plus an E2E test.

## Needs validation (no severity assigned)

### Dashboard anti-framing and deployed CSP

The shipped meta CSP allows inline script/style and cannot establish effective `frame-ancestors` protection (`web/index.html:7-8`). The recommended drag-and-drop flow does not require response headers, while the strict-host guidance does (`docs/backend/hosting.md:7-21,36-41`). Source confirms a separate confirmation for Debug OFF and typed `RESET` for Force Reset (`web/src/main.js:335-364,428-442`), so this audit did not establish that framing bypasses those interaction gates. Before production, observe the actual hosted response headers and perform a benign same-browser framing test with a dummy account. Require `frame-ancestors 'none'` or document an architecture-compatible alternative. OWASP recommends strict CSP as defense in depth ([OWASP CSP guidance](https://cheatsheetseries.owasp.org/cheatsheets/Content_Security_Policy_Cheat_Sheet.html)).

## Documentation audit

- **Self-sufficiency:** Pass. No canonical docs reference `plan.md`, `HANDOFF.md`, `AUDIT_CONTEXT.md`, or `AUDIT_PROMPT.md`; local Markdown targets inspected resolve.
- **Rate-limit contradiction:** `README.md:61-64,79-81`, `docs/backend/setup.md:26-30`, and `supabase/README.md:7-13` say to keep defaults, while `supabase/README.md:45-59` requires anonymous 10/hour/IP and owner signup/sign-in 10/5 minutes/IP. Supply exact dashboard steps and a verification check. Supabase currently documents anonymous and password-flow limits as separately configurable and recommends CAPTCHA/Turnstile for anonymous abuse ([anonymous sign-ins](https://supabase.com/docs/guides/auth/auth-anonymous), [rate limits](https://supabase.com/docs/guides/auth/rate-limits)).
- **Stale troubleshooting:** `docs/backend/troubleshooting.md:17` says a debug-blocked reset must be resolved locally, but the product supports owner-controlled remote Debug OFF (`web/src/main.js:320-370`).
- **Incorrect database doc:** `docs/backend/database.md:38-39` says a device can see its own `device_status`; actual policy/test are owner-only (`supabase/migrations/20261018133359_remote_rls_grants.sql:55-58`; `supabase/tests/remote_rls_test.sql:218-220`).
- **Overstated reset claim:** `README.md:9` implies Android 14+ always uses `wipeDevice()`. Code uses it only for eligible Device Owner cases; other tiers use Shizuku/manual behavior (`DeviceAdminManager.kt:109-158`).
- **Backup/restore gap:** The no-CLI user flow requires backup, but the suggested Dashboard backup is only “if available,” while the reliable alternative needs CLI/Docker and separate data export (`docs/backend/updates.md:53-60`). Provide a tested Free-plan export/restore path.
- **Unbounded history:** Cleanup covers anonymous identities, not actions, commands, events, or revoked devices (`supabase/migrations/20261018133630_remote_maintenance.sql:5-38`). `docs/backend/capacity.md:39-44` acknowledges no retention policy. Define thresholds and a bounded, auditable purge/export policy before quotas approach review levels.
- **Generated artifacts:** Static inspection found all nine ordered migrations exactly once and in prefix order for the sole release, 3.0.0. No stepwise update bundle is expected because no earlier release exists. Release and alias setup/verify files match their manifest hashes. Generator source rejects missing/duplicate/out-of-order coverage (`supabase/build-setup-sql.mjs:34-80`), but reproducibility was not executed because it writes tracked/generated files and target execution could not satisfy the audit sandbox contract.
- **Accessibility:** Source includes a skip link, associated labels, native forms/buttons, status messaging, and a confirmation dialog (`web/index.html:13,51-290`; `web/src/ui.js:42-79`). Keyboard focus trapping/restoration, screen-reader announcements, contrast, and browser behavior remain unverified.
- **Cloudflare:** Not applicable to the approved implementation: no Cloudflare Pages/WAF/cache configuration exists in the repository. No Cloudflare control was claimed or verified. If Cloudflare Pages is selected later, verify response CSP/anti-framing, cache behavior for session-bearing HTML, and provider settings against official Cloudflare documentation.

## Security assessment

| Area | Assessment |
| --- | --- |
| RLS/grants | Strong in source: FORCE RLS, owner/device predicates, no anon access, authenticated select-only. Fix future PUBLIC function defaults and strengthen deploy verification. |
| RPC authorization | Strong current boundary: non-anonymous owners, anonymous active devices, empty search path, explicit current grants. No cross-account bypass found. |
| Enrollment | Strong design: 256-bit random token, SHA-256 at rest, ten-minute expiry, single use, locking, replay checks. Clear browser token remnants. |
| Destructive boundary | Strong fail-closed local guard and interrupted-command behavior. Revocation during executing needs an explicit terminal/unknown result. Real device/wipe behavior remains unverified. |
| Keys/config | Publishable key is correctly treated as public; secret/service-role patterns are rejected. A tracked-source/docs pattern review found placeholders and validator/test constants, not a real key, password, private key, project ref, or database URL. Git-history and rebuilt-APK scans were not performed. |
| Realtime | Scoped subscriptions and invalidation-only handling are appropriate (`RemoteRealtimeClient.kt:44-79`; `web/src/main.js:134-166`). Exact deployed publication and quota usage remain unverified. |
| Browser | DOM rendering is XSS-conscious. Hosting integrity, session-bearing origin isolation, response CSP, anti-framing headers, and browser tests remain production gates. |
| Auth abuse | Source docs require rate limits, but configuration is external and contradictory. Verify exact live limits and strongly consider Turnstile/CAPTCHA for anonymous signup. |

## Architecture and update management

The approved per-user Supabase plus portable static dashboard model is coherent and avoids a central privileged service. Remote Management defaults off and source gates networking on valid config, enablement, enrollment, and unlocked state (`RemoteConfigStore.kt:30-48,103`; `ForegroundService.kt:84-95,141-208`). P2P/local behavior remains separate.

The flat immutable migration history plus generated release baselines and stepwise deltas is reasonable for this audience. It deliberately differs from Supabase's preferred team/production workflow, which uses version-controlled migrations, local/staging validation, and CLI/CI deployment rather than direct SQL Editor changes ([Supabase migrations](https://supabase.com/docs/guides/deployment/database-migrations), [environment management](https://supabase.com/docs/guides/deployment/managing-environments)). The deviation is justified for self-hosting simplicity only if setup/update verification, backups, and exact release checks are substantially stronger than the current `verify.sql`.

The build correctly ties asset merging to dashboard/SQL generation (`app/build.gradle:75-151`), but it may run `npm ci`, writes generated tracked paths, and therefore is not guaranteed offline/read-only. CI should pin Node/Java/Gradle, cache verified dependencies, regenerate in an isolated clean checkout, fail on diff, produce an SBOM/dependency report, enforce signing, and retain hashes/cert metadata.

Static contract comparison found Android wire enums/fields aligned with the SQL command types/states and reconcile parameters (`app/src/main/java/me/lucky/wasted/remote/domain/RemoteModels.kt:138-230`; `supabase/migrations/20261020131724_remote_debug_mode_commands.sql:164-255`). The transition graph restricts queued → received/expired/rejected, received → executing/debug-blocked/rejected/expired, and executing → applied/reset-initiated/debug-blocked/failed; per-command terminal allowlists are applied in the same RPC. Dashboard freshness uses the documented 150-second window (`web/src/timers.js:1-29`). Runtime serialization and clock behavior remain unverified.

## Verification status

### Proven by this audit

- Source-level identity, RLS/RPC, enrollment, state-machine, Debug Mode, dashboard DOM, build/release, and documentation traces described above.
- Nine migrations are listed once and in order for 3.0.0.
- `supabase/setup.sql` equals the release setup file; `supabase/verify.sql` equals the release verifier; their SHA-256 values match the manifest.
- No canonical documentation dependency on temporary planning artifacts was found.

### Unverified / required before production

- Clean fresh-project setup, migration replay, upgrade replay, linked-schema diff, RLS/RPC/concurrency suites, actual Auth toggles/rate limits, advisors, and quota state.
- Android unit/build results claimed in `AUDIT_CONTEXT.md`; signed certificate and APK secret scan.
- Repository-required API 24/33/35 emulator matrix plus auditor-added API 36 coverage; foreground-service receiver behavior, Doze/reboot/offline recovery, P2P regression, and Android 14-16 reset tiers.
- Two real-device enrollment/reconcile/command/P2P tests and settings sync under 500 ms.
- At least a 16-hour Debug-ON soak proving zero wipes, battery/load measurements, and Realtime/egress/connection usage.
- Browser compatibility, accessibility, clickjacking/header verification, auth initialization recovery, offline UI, and destructive confirmation flows.
- Real wipe E2E was **not run** and remains separately approval-gated on an emulator or sacrificial device.

### Commands run

Representative exact read-only commands were `git rev-parse HEAD`, `git status --short`, `rg --files ...`, `rg -n <patterns> ...`, `nl -ba <file>`, `sed -n <range> <file>`, `find . -type f ...`, and `shasum -a 256 supabase/releases/3.0.0/setup.sql supabase/releases/3.0.0/verify.sql supabase/setup.sql supabase/verify.sql`. Official current Supabase, Android, and OWASP documentation was consulted. No Gradle, Node project script, SQL suite, Supabase CLI, browser, emulator, device, remote database, dependency installation, or network target was executed.

The dynamic-receiver concern was investigated but not confirmed: Android 14 requires export flags for runtime receivers except filters containing only system broadcasts; these filters appear system-only. Preserve the API 33/35/36 runtime gate and use version-compatible explicit registration only after confirming the correct exported semantics ([Android 14 behavior changes](https://developer.android.com/about/versions/14/behavior-changes-14)).

## Prioritized action plan

### P0 — release blockers

1. Fix M1 and make database verification fail closed; add effective PUBLIC ACL and exact-security catalog tests.
2. Fix M2 with explicit revocation semantics and concurrency/state-transition coverage.
3. Validate production anti-framing/CSP headers and adopt a documented host constraint or architecture-compatible alternative.
4. Reconcile and verify exact Auth limits; enable abuse protection appropriate to anonymous signup.
5. Complete fresh/upgrade SQL replay, linked-project tests, signed APK checks, the API 24/33/35 matrix, and 16-hour zero-wipe soak. Add API 36 and two-device/P2P testing as auditor-recommended coverage for the current target SDK and client acceptance criteria.

### P1 — correctness and operational safety

1. Make production release signing mandatory and certificate-verified.
2. Bind idempotency keys to action type/scope and add cross-RPC tests.
3. Revoke default function execution from PUBLIC and test effective privileges.
4. Clear enrollment token DOM state; validate optional-link schemes; add owner initialization recovery.
5. Correct the documented inconsistencies above and publish a tested Free-plan backup/restore path.
6. Define retention, monitoring evidence, and capacity response thresholds.

### P2 — hardening

1. Consider recent authentication/MFA or a typed device-name confirmation before remotely disabling Debug Mode.
2. Replace inline CSP allowances with generated hashes/nonces where the chosen host supports headers.
3. Add browser/a11y automation, dependency/SBOM checks, generator reproducibility checks, and explicit unsigned-build isolation.

## Open questions

1. Does the client approve explicit Create Account instead of automatic creation after failed sign-in?
2. What terminal state should represent a device revoked while a Force Reset is already executing: failed, cancelled, or outcome unknown?
3. Is header-capable hosting mandatory for production, or must the single-file artifact implement an alternative frame-busting/confirmation design?
4. What retention period is required for command/action/event audit history?
5. Which tested backup/restore workflow must be supported for Free-plan, non-CLI users?

## Audit metadata

- **Scope read:** `AUDIT_PROMPT.md`, `AUDIT_CONTEXT.md`, `archive/wasted update.txt`, `README.md`, every file linked by `docs/README.md`, `supabase/README.md`, `web/config.example.js`, Android `remote/**`, `ResetExecutor.kt`, `ForegroundService.kt`, related manifest/reset entry paths, `app/build.gradle`, `web/**`, `supabase/migrations/**`, `supabase/tests/**`, `supabase/releases.json`, `supabase/releases/3.0.0/**`, and `supabase/build-setup-sql.mjs`.
- **Execution boundary:** source and trusted read-only utilities only; no live probes or target-controlled tests.
- **Prior audit ledger:** none found. This is one standard pass, not proof that no undiscovered defect exists.
- **Repository changes:** only this `AUDIT_REPORT.md` was created. No code, docs, SQL, configuration, generated artifact, device, or remote system was modified; no commit was made.
