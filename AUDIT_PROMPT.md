# Re-audit Prompt (focused)

You are an independent senior auditor. This is a **re-audit**, not a full fresh audit. Verify that the
previous findings were fixed, check for regressions in the changed areas, and report only residual or
new issues. Be very concise; do not restate fixed findings or the whole codebase.

- Previous report: `AUDIT_REPORT.md`
- Implementing context: `AUDIT_CONTEXT.md`
- Client requirements: `archive/wasted update.txt`
- Write your report to **`AUDIT_REPORT_2.md`** (do not overwrite the first report).

## Ground rules

- Read-only: do not modify code, docs, SQL, or config. Only create `AUDIT_REPORT_2.md`.
- Never trigger the real wipe path; no device installs or destructive tests.
- Do not invent facts. Mark anything not verified as **Unverified**.
- Load the installed `security-audit` skill (Cloudflare security skill). No UI redesign suggestions.
- No over-engineering: minimum practical fixes only; respect the approved architecture.

## Changes since the first audit (verify these)

- **Migrations**: added and applied `20261021060654_remote_hardening.sql` and
  `20261021061300_remote_public_acl.sql`; `supabase/releases.json` now lists 11 migrations; setup,
  release folder, manifest, and verify were regenerated.
- **M1 verifier**: `supabase/verify.sql` expanded to 18 fail-closed catalog checks (FORCE RLS,
  exact policies/grants, RPC signatures/definer/owner/empty search_path/ACL, Realtime scope, cron,
  schema marker `wasted-remote-schema:1`, PUBLIC default denial).
- **M2 revocation**: `revoke_device` now terminalizes `executing` commands as
  `failed`/`device_revoked_during_execution`; test added.
- **L2 idempotency**: `create_account_action` binds keys to action type/scope; cross-type tests.
- **L3 ACL**: global `PUBLIC` execute default revoked; probe test added to the RLS suite.
- **L1 signing**: `assembleSignedRelease` / `verifyReleaseSigning`; unsigned output named `-unsigned`.
- **L4–L6 web**: enrollment token cleared on expiry/sign-out/new token; optional links HTTPS-only;
  owner-profile recovery panel (`account-setup`); command labels.
- **Anti-framing**: `web/_headers` + frame-busting fallback; host-header requirement documented.
- **Docs**: corrected rate limits, `device_status` RLS visibility, Android reset wording, backup and
  retention policy, revocation/`reset_initiated` semantics, signing, headers, and release checklist;
  added `docs/backend/quickstart.md`. Added a note on re-running migrations and pre-release baselines.

Files changed: `README.md`, `plan.md`, `app/build.gradle`, `web/**`, `app/src/main/assets/**`,
`supabase/migrations/*hardening*`, `*public_acl*`, `supabase/tests/**`, `supabase/verify.sql`,
`supabase/releases.json`, `supabase/releases/3.0.0/**`, `supabase/README.md`, `docs/backend/**`.

## Checks

1. Open `AUDIT_REPORT.md`; mark every finding Fixed/Partial/Open with file/line evidence.
2. Verify M1/M2 and L1–L6 specifically; run safe local checks if possible.
3. Check regressions in changed areas: RLS/grants/RPC behavior, revocation transitions, idempotency,
   signing gate, dashboard auth/token handling, CSP/frame headers.
4. **Multi-device and lifecycle UX**: verify the docs/wizard clearly separate (a) first deployment,
   (b) additional device on an existing backend, and (c) app update. Confirm no flow tells a second
   device to re-run `setup.sql`, change Auth settings, or reuse an enrollment token; confirm
   independent per-device tokens work; check that a user with many devices cannot get stuck at a
   step because another device already initialized the backend.
5. Check the requirements matrix deltas and whether the doc corrections are accurate.
6. Only widen the audit if a concrete new issue demands it.

## Output (`AUDIT_REPORT_2.md`, concise)

1. Verdict and whether previous findings are closed.
2. Finding-by-finding status with evidence.
3. New/residual findings by severity (Blocker/High/Medium/Low), with minimal fix.
4. Requirements deltas since the first audit.
5. Unverified items and the exact evidence still needed (fresh/upgrade replay, Docker diff,
   emulator/soak, Auth settings, headers, certificate).
6. Open product decisions only (auto-create, retention period, backup workflow, header-capable host).
7. Commands run and “no code changes made”.
