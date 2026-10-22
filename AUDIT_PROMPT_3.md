# Final Production & Security Audit Prompt (third audit)

You are an independent senior security and release auditor. This is the **final production gate**
after the fixes for `AUDIT_REPORT_2.md`. Verify that the P0/P1 findings are actually closed, perform a
current **OWASP Top 10 security audit**, check for regressions in the changed surfaces, and decide
whether the project is production-ready.

Be concise and evidence-first. Do not restate fixed findings or re-review the whole codebase unless
a concrete issue requires it. Do not redesign the product or propose speculative features.

## Inputs

- Previous report: `AUDIT_REPORT_2.md`
- Implementing context: `AUDIT_CONTEXT.md`
- Architecture/verification handoff: `HANDOFF.md`
- Client requirements: `archive/wasted update.txt`
- Canonical docs: `docs/README.md`, `docs/backend/*`
- Write your report to **`AUDIT_REPORT_3.md`** (do not overwrite prior reports).

## Ground rules

- Read-only: do not modify code, docs, SQL, config, generated assets, or the database. Only create
  `AUDIT_REPORT_3.md`.
- Never trigger the real wipe path, factory reset, or destructive command. No physical-device
  installs. Use static inspection and safe local checks only.
- Do not accept claims from `HANDOFF.md`/`AUDIT_CONTEXT.md` as proof. Verify in source, generated
  artifacts, SQL, or observed output. Mark anything unexecuted as **Unverified**.
- Use the installed `security-audit` skill (Cloudflare security skill) for security review.
- Use the current **OWASP Top 10** as the security framework. For Android-specific controls also
  spot-check OWASP MASVS/MASTG concerns (storage, crypto, auth, network, platform interaction, code
  quality, resilience). Running safe dependency/secret scanners (`npm audit`, Gradle dependency
  inspection, tracked-source/APK secret scans) is allowed; do not attempt exploits or target live
  services.
- Do not treat scanner output as proof. Confirm each finding in source/config or observed output.
- No secrets, project refs, account credentials, or real device data in the report.
- If a required fix is absent, mark it **Open** and the verdict **NOT PRODUCTION-READY**.

## OWASP Top 10 security audit

For every category, report **Pass / Fail / N/A**, severity, and concrete evidence. Do not just list
category names.

- **A01 Broken Access Control:** RLS/FORCE RLS, RPC owner/device checks, cross-account and cross-device
  isolation, revocation, enrollment binding, single-owner guard, no direct table writes.
- **A02 Cryptographic Failures:** HTTPS-only project/website URLs, TLS, encrypted preference/session
  storage, token hashing, no plaintext passwords/secrets, Android Keystore/Tink usage.
- **A03 Injection:** parameterized RPCs, no dynamic SQL from user input, dashboard XSS (`textContent`,
  no `innerHTML`), command/URL injection, input normalization, CSP.
- **A04 Insecure Design:** fail-closed configuration, destructive-action confirmations, Debug Mode
  boundary, enrollment token design, single-owner bootstrap, abuse/resource limits.
- **A05 Security Misconfiguration:** CSP and anti-framing headers, `_headers` deployment, CORS,
  publishable vs secret keys, Auth settings (Confirm email/anonymous/rate limits), debug logging.
- **A06 Vulnerable and Outdated Components:** Android/Gradle dependencies, Supabase SDK/web packages,
  known CVEs, unpinned/deprecated libraries, `npm audit`, dependency lockfiles.
- **A07 Identification and Authentication Failures:** owner email/password, Confirm email, password
  policy, session storage/refresh, anonymous device auth, signup abuse, sign-out/session clearing.
- **A08 Software and Data Integrity Failures:** signed APK, release checksums, generated SQL/setup
  artifacts, update bundle integrity, supply-chain scripts, no unsigned release publication.
- **A09 Security Logging and Monitoring Failures:** no secrets/tokens/device data in logs, command
  audit events, failure visibility, redaction, retention, no sensitive crash payloads.
- **A10 Server-Side Request Forgery:** user-controlled Supabase project URL validation, optional
  dashboard links restricted to HTTPS, no arbitrary server-side fetch, host allowlists.

Also flag any security issue outside the Top 10 if concrete. Keep fixes minimum and practical.

**Security tooling:** use what is available and safe — `npm audit`/lockfile review, Gradle
dependency/version inspection with CVE lookup, tracked-source and rebuilt-APK secret scans,
header/framing checks, and static Android MASVS review. A passive local OWASP ZAP scan is optional;
do not run active attacks against a live deployment. Record tools/commands and their results in the
report.

## Implementation snapshot (verify, do not assume)

- Fourteen migrations are tracked; the latest are `20261021150306_remote_single_owner.sql` and
  `20261021150716_remote_legacy_revocation_repair.sql`.
- `verify.sql` now does exact policy matching and an effective default-ACL probe; the negative
  drift test is `supabase/tests/remote_verify_drift_test.sql`.
- The single-owner guard is in `initialize_owner_account`; the legacy repair function is
  `private.repair_legacy_revoked_commands()`.
- The app wizard exports a deployable ZIP with `index.html` + `_headers`.
- Sign In no longer enforces a 12-character minimum; Create Account still does.
- Documentation claims a single cumulative update contract, 25 web tests, and notifications ON.

## Required fixes to verify

1. **R2-M1 — verifier must prove tenant isolation**
   - `verify.sql` compares `pg_policies` to a canonical expected set containing table, policy name,
     command, roles, permissive/restrictive mode, and normalized `qual`/`with_check`.
   - Extra policies and mismatched predicates must fail; counting names or SELECT commands is not
     enough.
   - The default-function ACL check must detect removal of the explicit global PUBLIC deny, or use
     an effective create-function privilege probe in a controlled transaction.
   - Negative tests intentionally introduce a permissive/extra policy and a missing default ACL and
     require `verify.sql` to fail.

2. **R2-M2 — public-signup control**
   - The implemented control is a single-owner guard in `initialize_owner_account`: only the first
     authenticated owner can initialize; extra Auth users are inert.
   - Verify the live Auth configuration through Supabase MCP/settings if available. Confirm email
     is not a signup restriction.
   - Confirm the control does not break anonymous device sign-ins. Flag residual MAU/resource abuse
     from public Auth signups if disabling email signups or host access control is required.

3. **Anti-framing deployment**
   - The app exposes a deployable ZIP containing `index.html` and `_headers`; verify the ZIP
     contents and that the production path uses it.
   - If claimed deployed, verify actual response headers and a benign framing test; a repository
     `_headers` file alone is not proof.

4. **R2-L1 — sign-in password policy**
   - Sign In no longer blocks a shorter existing owner password client-side. The 12-character rule
     applies only to Create Account unless the same minimum is enforced server-side for existing
     owners.

5. **R2-L2 — legacy stranded commands**
   - Query the linked project for `executing` commands belonging to already-revoked devices.
   - If any exist, verify a forward-only, idempotent repair marks them with the unknown-outcome
     result and inserts exactly one audit event. Do not retry destructive work.

6. **R2-L3 — documentation consistency**
   - Independent enrollment tokens vs “new token revokes older” wording.
   - Current test counts (web 25/25, Android 95/95; verify actual).
   - Notifications default (source says ON; README and docs must agree).
   - Migration count in HANDOFF vs `releases.json`.
   - Manifest contents (migration lists vs versions/hashes/update metadata).
   - One clear update contract: direct cumulative bundle from any earlier release. Generated
     wording, release-note template, and handoff must agree.
   - Netlify password/claim behavior described as provider behavior, not repository behavior.

7. **R2-L4 — clipboard warning**
   - The dashboard warns that copied enrollment tokens remain in the OS clipboard/history and advises
     overwriting after enrollment.

8. **Release evidence gates** (mark Unverified if not executed)
   - Fresh-project `setup.sql`, `verify.sql`, all four SQL suites, migration parity, advisors, quota.
   - Upgrade replay from the prior schema, including legacy command repair.
   - Android 95/95, web 25/25, clean build, signed-release certificate identity, secret scans,
     generated-artifact clean diff.
   - API 24/33/35 (and current target) emulator matrix; foreground/service/reboot/Doze/offline.
   - Two real devices: independent enroll, reconcile, rename/revoke/re-enroll, commands, settings
     latency <500 ms, P2P regression.
   - Browser auth/confirmation/recovery, keyboard/screen-reader, offline/error, destructive dialogs.
   - 16-hour Debug-ON zero-wipe soak, battery/load, Supabase Free-plan/quota observations.
   - Wipe E2E remains separately approval-gated.

## Regression checks for the latest changes

- Email input filtering: invalid characters blocked before insertion, lowercase, no whitespace,
  duplicate `@` blocked, paste handled, form still validates. Password fields keep spaces (valid
  password characters) and the eye toggle works without submitting.
- Sign In/Create Account split, Confirm email flow, `emailRedirectTo`, Auth Site URL, pending account
  name.
- Device name sent at claim, dashboard Rename/Revoke, revoke terminalization, re-enroll via Reset
  enrollment.
- Confirmation dialogs for settings/token/Debug/Reset/Force/revoke; no direct command dispatch.
- Netlify same-site update guidance and regenerated `index.html`.
- RLS/RPC ownership, idempotency binding, revocation transitions, Debug Mode boundary, P2P unaffected.

## Report format (`AUDIT_REPORT_3.md`)

1. Verdict: **PRODUCTION-READY** or **NOT PRODUCTION-READY**.
2. Finding-by-finding status for R2-M1/M2 and R2-L1–L4: Fixed / Partial / Open, with file:line
   evidence.
3. **OWASP Top 10 matrix** (A01–A10): Pass/Fail/N/A, severity, evidence, minimal fix. Add Android
   MASVS notes where relevant.
4. New or residual findings by severity (`Blocker`, `High`, `Medium`, `Low`), each with a minimal
   practical fix.
5. Production gates: executed vs Unverified, with exact missing evidence.
6. Requirements/behavior deltas.
7. Open product decisions that still block release.
8. Commands/scanners run and “no code changes made”.

Only production-ready if every P0 item and the required release evidence is closed. Otherwise be
explicit about what would change the verdict.
