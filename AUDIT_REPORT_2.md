# Wasted Remote v3.0.0 — Focused Re-audit

**Audit date:** 2026-10-21  
**Revision reviewed:** `03cd360b69f3f44a6cfc69f30f0ebbfc623c4f65`  
**Method:** static, read-only re-audit of the first report's findings and the changed Android, web,
SQL, release, and documentation surfaces. No app build, project script, database command, browser,
emulator, physical-device action, or wipe path was executed.

## Verdict

The remediation is substantial, but the project is **not yet production-ready**.

- Six prior findings are fixed in source: L1, L2, L3, L5, L6, and the forward behavior in M2.
- L4 is fixed for page state; clipboard persistence remains an unavoidable/documentation residual.
- M1 is only partially fixed. The verifier now fails closed and checks many important catalog
  invariants, but it can still report PASS for a database with a permissive tenant-bypassing policy
  or with the intended default-function ACL removed.
- Strict anti-framing remains unproven in the primary app-generated, single-file deployment flow.
- New issues include a sign-in validation regression, missing upgrade repair for commands stranded
  by the old revocation function, and documentation contradictions.
- No confirmed Blocker or High vulnerability was found. Production approval remains blocked by the
  Medium findings and the unexecuted release gates below.

## First-audit finding status

| ID | Status | Re-audit result |
| --- | --- | --- |
| M1 — verifier can pass insecure DB | **Partial / open** | `verify.sql` now raises on failure and checks FORCE RLS, grants, RPC properties, Realtime scope, schema marker, and default ACLs (`supabase/verify.sql:35-149`). Its policy check only counts expected policy names whose command is SELECT; it does not bind names to tables, compare roles/mode/expressions, or reject extra SELECT policies (`:52-60`). Its default-ACL check only detects existing PUBLIC grants and does not prove the required explicit global deny still exists (`:125-132`). |
| M2 — revocation strands executing command | **Fixed forward; upgrade gap** | The replacement function terminalizes queued/received commands as rejected and executing commands as failed with `device_revoked_during_execution` (`supabase/migrations/20261021060654_remote_hardening.sql:10-63`), with regression coverage (`supabase/tests/remote_rpc_test.sql:774-855`). It does not repair rows stranded before the migration; the already-revoked early return prevents a later revoke call from doing so (`hardening.sql:28-30`). |
| L1 — release signing not fail-closed | **Fixed in workflow** | Unsigned output is explicitly named `-unsigned`; `assembleSignedRelease` requires signing inputs and the documented release gate verifies the certificate (`app/build.gradle:68-105`; `docs/backend/verification.md:36-43`). The actual release APK and certificate were not rebuilt/rechecked in this audit. |
| L2 — idempotency key not bound to action | **Fixed** | Both normal and unique-conflict paths reject a key reused for another action type/scope (`hardening.sql:95-103,139-151`), with cross-type and cross-RPC tests (`remote_rpc_test.sql:343-356,479-484`). |
| L3 — future functions executable by PUBLIC | **Fixed in source** | The global and schema-specific default privileges revoke PUBLIC execution (`20261021061300_remote_public_acl.sql:1-6`; `hardening.sql:155-158`), and the RLS suite includes an effective newly-created-function probe (`remote_rls_test.sql:208-225`). Deployment is unverified. |
| L4 — enrollment token retained | **Fixed, with clipboard residual** | Replacement, expiry, auth loss, and explicit sign-out clear the rendered token (`web/src/main.js:128-141,623-675,694-699`). Content already copied to the operating-system clipboard cannot be recalled; the UI should state this briefly. |
| L5 — optional links accept unsafe schemes | **Fixed** | Optional links are parsed and shown only for HTTPS (`web/src/main.js:111-126`). |
| L6 — partial Auth user has no recovery | **Fixed in source** | Confirm-email signup retains the requested handle and authenticated users without an account row receive a retryable Finish Account Setup flow (`web/src/auth.js:137-154`; `web/src/main.js:149-163,503-528`). Browser behavior is not covered by automated DOM/E2E tests. |
| Anti-framing validation | **Partial / unverified** | `_headers` correctly provides CSP `frame-ancestors 'none'` and `X-Frame-Options: DENY` (`web/_headers:1-6`), and the page has a best-effort frame buster (`web/index.html:7-15`). However, the app exports only `index.html` and directs the user to upload that file (`RemoteSetupActivity.kt:314-354`); only the developer web build copies `_headers` (`web/build.mjs:13-15`). The primary deployment therefore does not establish strict response-header protection. |

## New and residual findings

### Medium

#### R2-M1 — Production verifier still does not prove tenant-isolation policies

`supabase/verify.sql:52-60` counts seven expected policy names with `cmd = 'SELECT'`, regardless of
which expected table each name belongs to, its roles, permissive/restrictive mode, or its `qual` and
`with_check` expressions. It also permits additional SELECT policies. A drifted or extra permissive
`USING (true)` policy can therefore expose cross-account rows while all current verifier rows still
say PASS.

The future-function check at `supabase/verify.sql:125-132` has a related false-green case: removing
the explicit global default-ACL row can restore PostgreSQL's implicit PUBLIC function execution,
while the query sees no ACL row containing a PUBLIC grant and returns zero/PASS.

**Required fix:** compare `pg_policies` against a canonical expected relation containing table,
policy name, command, roles, permissive mode, and normalized predicates; reject extras. Validate the
required global default-ACL state or perform an effective create-function privilege probe in a
controlled transaction. Add negative tests that intentionally introduce each drift and require
`verify.sql` to fail.

#### R2-M2 — Public account creation can consume a self-hoster's free-tier resources

The generated dashboard is public and any visitor can attempt signup; there is no single-owner or
invitation guard, CAPTCHA remains optional, and the main control is manually configured per-IP rate
limits (`docs/backend/security.md:50-60,85-91`). RLS prevents cross-account reads, so this is not a
tenant-isolation bypass. It is an availability/cost risk: distributed valid-email signups can create
Auth users and application rows and consume the project owner's constrained MAU/database budget.

**Required decision/fix:** for the intended one-owner-per-project model, choose and document one
enforceable control before public deployment: disable new email signups after owner bootstrap, add a
single-owner/invitation guard, or require host access control. Keep the documented rate limits and
consider CAPTCHA as defense in depth. Verify the live setting; Confirm email is not a signup guard.

### Low

#### R2-L1 — Sign-in incorrectly requires a 12-character password

The Sign In input has `minlength="12"` (`web/index.html:42-45`) and submission calls
`reportValidity()` before Supabase Auth (`web/src/auth.js:65-76`). An existing valid owner whose
project permits a shorter password is blocked client-side even though Supabase could authenticate
them. Apply the product's new-password rule only to Create Account, or first enforce and verify the
same server-side minimum for every existing owner.

#### R2-L2 — Revocation migration does not repair legacy stranded commands

The new `revoke_device` behavior fixes future revocations, but the migration contains no data repair
for `executing` commands belonging to devices already revoked by the earlier implementation. Its
early return for an already-revoked device (`hardening.sql:28-30`) also prevents the owner from
repairing those rows by repeating revoke.

**Fix:** before production upgrade approval, query the linked project for such rows. If any earlier
schema was deployed, add a forward-only, idempotent migration that terminalizes them with the same
unknown-outcome result and inserts exactly one audit event. Do not infer or retry destructive work.

#### R2-L3 — Documentation contains contradictory operational claims

- Multiple enrollment tokens are independent in code and tests, but `docs/backend/security.md:12`
  and `docs/backend/updates.md:86-87` say a new token revokes older open tokens.
- Current claims say web tests are 22/22, but `docs/backend/verification.md:13` and
  `docs/backend/release-checklist.md:31-32` still say 19.
- Remote notifications default ON in source, while `README.md:124` says OFF.
- `HANDOFF.md:82` says nine migrations; `supabase/releases.json` lists twelve.
- `docs/backend/migrations-and-releases.md:85` says generated manifests contain migration lists,
  but the generator emits versions, hashes, and update metadata only
  (`supabase/build-setup-sql.mjs:239-252`).
- The generator produces a direct cumulative bundle from each prior release
  (`supabase/build-setup-sql.mjs:219-226`), matching `docs/backend/updates.md:13-19`, but generated
  wording, the release-note template (`updates.md:32-36`), and `HANDOFF.md:165-185,252` also tell
  users to apply intermediate bundles stepwise. Choose one supported upgrade contract before a
  second release makes the contradiction operationally significant.
- `README.md:84-86` says an unclaimed Netlify Drop site is password-protected. The cited workflow
  needs provider verification; the repository supplies no password configuration.

Correct these before using the docs as a release runbook. Prefer generated/current counts where
possible, and distinguish repository behavior from hosting-provider behavior.

#### R2-L4 — Enrollment-token clipboard exposure is not explained

The dashboard now clears its own token display correctly, but cannot clear copies retained by the
OS clipboard or a clipboard-history service. Add a short warning beside Copy/expiry and advise the
owner to overwrite sensitive clipboard content after enrollment. The server's single-use and
ten-minute expiry controls keep this Low.

## Requirements and behavior deltas

- **Multiple devices:** implemented coherently. The newest migration preserves independent open
  tokens (`20261021070916_remote_multi_enrollment.sql:1-24`); RPC/concurrency tests cover two tokens
  and devices. The setup wizard and canonical setup docs distinguish first deployment, additional
  devices, and database updates. Runtime two-device evidence remains open.
- **Owner vs device identity:** the Android app stores an encrypted anonymous device session, not
  the owner's password. Device names are independent of the owner account name and can be edited in
  Android or renamed/revoked through owner RPCs.
- **Account creation:** explicit Create Account remains a deliberate deviation from the archived
  “auto-create if feasible” wording. Confirm email and recovery are now supported, but the client
  still needs to accept this deviation and the public-signup policy.
- **Notifications:** meaningful-event-only notifications remain a documented product decision, but
  the README default is stale as noted above.
- **Reset behavior:** the destructive boundary and typed Force Reset confirmation remain intact.
  Real Android reset behavior and wipe outcome were not exercised.

## Release and artifact integrity

Static release structure is internally consistent:

- `supabase/releases.json` lists all twelve migration files in order.
- Release, root, and APK-asset `setup.sql` files are byte-identical with SHA-256
  `d7fda5075dc78452c7137dc289b2cae6ef38915dda2e3de37ecaa255276ae0e0`.
- Release and root `verify.sql` files are byte-identical with SHA-256
  `d749a27c6c7e3f33d5f1715c623a971d49b7e397139f78eb8cf4f5eaf0a21e72`.
- Those hashes match `supabase/releases/3.0.0/manifest.json`.
- No update bundle is expected while 3.0.0 is the only declared release.

This proves repository consistency, not that the linked or a fresh Supabase project has applied the
same SQL.

## Implemented but unverified production gates

The following claims came from project handoff/context and were not independently executed in this
re-audit. They must remain release-blocking evidence gates:

1. Linked-project migration parity, `verify.sql` results, all four SQL suites, Auth settings,
   advisors, and quota headroom.
2. Fresh-project `setup.sql` install and a real upgrade replay, including the legacy revocation-row
   query/repair decision.
3. Android 92/92 and web 22/22 tests, clean build, signed-release certificate identity, dependency
   audit, tracked/history/APK secret scans, and generated-artifact clean-diff check.
4. API 24/33/35 minimum emulator matrix (plus API 36 for the current target), foreground service,
   reboot/Doze/offline recovery, P2P regression, and Android reset-tier behavior.
5. Two real devices independently enroll, reconcile, rename/revoke/re-enroll, receive commands, and
   preserve P2P; settings synchronization is measured below 500 ms.
6. Browser auth/account-recovery/confirmation flows, keyboard and screen-reader accessibility,
   offline/error behavior, and destructive-action dialogs. Current web tests do not exercise the
   DOM/auth controller flows identified above.
7. The deployed dashboard response actually sends the required anti-framing, nosniff, and referrer
   headers. Uploading only the app-generated `index.html` is insufficient evidence.
8. A 16-hour Debug-ON zero-wipe soak, battery/load measurements, and Supabase database/egress/MAU/
   Realtime/connection observations against the documented free-plan thresholds.
9. Real wipe E2E remains separately approval-gated and was not run.

## Prioritized production plan

### P0 — before production approval

1. Close R2-M1 and prove the verifier fails for intentionally weakened/extra policies and a missing
   global default ACL.
2. Decide and enforce the public-signup ownership model (R2-M2); observe the real Auth configuration.
3. Make a header-capable deployment package/path the production path, deploy it, and verify response
   headers with a benign framing test.
4. Complete fresh/upgrade SQL, signed APK, emulator/device, browser, P2P, latency, soak, and quota
   gates listed above.

### P1 — correctness and runbook quality

1. Remove the sign-in-only password length restriction.
2. Audit the linked database for legacy stranded commands and ship an idempotent backfill if needed.
3. Correct the documentation contradictions and add auth/DOM browser regression coverage.
4. Add the enrollment-token clipboard warning.

## Open decisions

1. Is a header-capable folder deployment mandatory, or must the app export a deployable package
   containing both `index.html` and `_headers`?
2. After the first owner is created, should email signup be disabled, single-owner-guarded, or
   protected by host access control/invitations?
3. Does the client formally accept explicit Create Account rather than auto-creation after failed
   sign-in?
4. What retention and tested Free-plan backup/restore workflow are release requirements?

## Commands and change boundary

Representative read-only commands used were `git status --short`, `git rev-parse HEAD`, `rg`,
`sed`, `nl`, `find`, and `shasum -a 256`. No Gradle, Node project script, Supabase CLI, SQL,
browser, emulator, device, dependency installation, or network target was run.

**Repository change made by this re-audit:** this `AUDIT_REPORT_2.md` only. No source, SQL,
configuration, documentation, generated artifact, remote system, or device was changed; no commit
was created.
