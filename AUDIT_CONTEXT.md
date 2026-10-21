# Audit Context — Remote Management (v3.0.0)

This file is written by the implementing agent for an independent auditor. It summarizes what was
built, what is verified, what is not, and which decisions to scrutinize. It contains no secrets.
The client requirements are in `archive/wasted update.txt`; canonical technical documentation is in
`docs/` (self-sufficient, no dependency on this file or on temporary planning artifacts).

**Changes since the first audit:** see the “Changes since the first audit” section in
`AUDIT_PROMPT.md` for the exact fixes, new migrations, and changed files. The first audit's findings
are in `AUDIT_REPORT.md`.

## What this project is

Wasted (Modded) is an Android app (minSdk 24) with Device Admin, local triggers, P2P, and an optional
Remote Management layer:

- Remote Lock Timer / USB Trigger sync, Reset Timer, Force Reset.
- Device registration, status/timer reporting, Debug Mode status.
- Optional notifications, offline-safe behavior.
- A lightweight, portable, self-hosted dashboard.

**Deployment model:** every user creates their **own Supabase project** and hosts their **own
dashboard copy**. There is no shared backend or central dashboard URL. The app's setup wizard
collects the project URL + publishable key, provides the SQL and Auth checklist, and generates a
single-file dashboard saved via Android SAF. Supabase Cloud is the backend; Docker is local-dev only.

## Current status

- App v3.0.0 (versionCode 42); debug and release APKs build and are signed.
- Android unit tests: 92/92. Web unit tests: 19/19. SQL suites: 4/4 (schema, RLS, RPC,
  concurrency) against the linked project in rolled-back transactions.
- Static security checks: only `ResetExecutor` reaches `wipeData()`; Supabase client creation only
  behind the fail-closed config gate; tracked-source secret scan clean; APK scan finds no key
  material/project URL; CSP + `no-referrer` shipped; dependencies audited (0 vulnerabilities).
- Database: 12 MB on the linked project; migration history matches 9 tracked migrations.
- **Not yet verified:** fresh-project install, upgrade-path replay, Docker clean replay/diff,
  emulator/device matrix, 16-hour soak, latency/battery, browser/a11y suites, Usage/Realtime
  reports, real wipe E2E (needs separate approval).

## Key decisions (scrutinize these)

1. **Per-user self-hosting** (client requirement): each user runs their own Supabase + dashboard.
2. **App-generated dashboard, no runtime connect form:** app injects URL + publishable key into a
   bundled template and exports via SAF. No file editing. A shared/central dashboard URL and
   localStorage-based runtime config were rejected.
3. **Setup = one `setup.sql` in SQL Editor + two Auth toggles** (enable anonymous sign-ins, disable
   Confirm email). No CLI/Docker for end users; Docker is not an end-user deployment path.
4. **Migrations:** flat immutable history (`supabase/migrations/`) because Supabase CLI requires it;
   `releases.json` maps app version → schema version → cumulative migrations; per-release folders
   (`supabase/releases/<version>/`) contain generated `setup.sql`, stepwise update bundles,
   `verify.sql`, checksums, and generated instructions. **No automatic update check**; release notes
   name the bundle.
5. **Publishable key is public by design; secret/service-role keys never ship.** The dashboard
   contains only URL + publishable key.
6. **Debug Mode:** default ON, encrypted, re-read inside `ResetExecutor`; remote Force Reset blocked
   while ON; remote per-device toggle requires owner action and supersedes pending Force Resets.
7. **Explicit Create Account** instead of the spec's “auto-create if feasible” wording (safer; flagged
   as a deviation for client confirmation).
8. Notifications only for meaningful events (no heartbeat-success spam; manual sync success only).
9. Views/ViewBinding (no Compose rewrite), minSdk 24 retained.

## Specific claims to verify (don't take the docs on faith)

- RLS is enabled/forced; `anon` has no table access; `authenticated` is select-only; writes only via
  SECURITY DEFINER RPCs; default privileges hardened.
- Owner/device isolation, revocation behavior, enrollment token hashing/single-use/10-minute expiry,
  idempotency keys, command/action consistency trigger.
- Force Reset ordering and terminal allowlists; interrupted `executing` rows never replay
  destructively; Debug Mode re-read at every boundary.
- `set_device_debug_mode` targets one device; OFF expires pending Force Resets
  (`superseded_by_debug_off`).
- Settings revisions apply only when newer; status fields and TTLs match the docs.
- Generated SQL covers every migration exactly once, per-release bundles are stepwise and
  checksummed, and Gradle regenerates the assets before asset merging.
- The dashboard uses `textContent` (no `innerHTML`), validates keys/URLs, and rejects secret keys.

## Where to look

- Requirements: `archive/wasted update.txt`.
- Canonical docs: `docs/README.md` and `docs/backend/*`.
- App: `app/src/main/java/me/lucky/wasted/remote/**`, `admin/ResetExecutor.kt`,
  `trigger/shared/ForegroundService.kt`.
- Dashboard: `web/`.
- Backend: `supabase/migrations/`, `supabase/tests/`, `releases.json`, `releases/3.0.0/`,
  `build-setup-sql.mjs`.
- Build: `app/build.gradle`, `web/build*.mjs`.

## What I want from the audit

1. A requirements matrix against the client spec (Done/Partial/Missing/Extra/Deviation, with lines).
2. Security findings by severity with evidence and fixes.
3. Documentation accuracy/completeness check (including whether it is truly independent and
   sufficient).
4. Validation of the migration/release/update strategy against industry practice.
5. A clear separation of “implemented and proven” vs “implemented but unverified”.
6. Concrete, prioritized next steps. Do not change code; write only `AUDIT_REPORT.md`.

## Constraints

- Do not run the real wipe path or install/test on a physical device.
- Do not modify files other than `AUDIT_REPORT.md`; do not commit.
- If you cannot verify something statically, mark it Unverified rather than guessing.
- No secrets, project refs, or real account/device data in the report.
