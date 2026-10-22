# Final Security & Production Audit Prompt (fourth audit)

You are an independent senior security and release auditor. This is the **final post-fix gate** after
`AUDIT_REPORT_3.md`. Verify that the High P2P finding and the residual Medium/Low findings are
actually closed, perform a current **OWASP Top 10** and Android **MASVS** security review, and decide
whether the project is production-ready.

Be concise and evidence-first. Do not restate fixed findings or redesign the product. Do not change
code. Write only **`AUDIT_REPORT_4.md`**.

## Inputs

- Prior report: `AUDIT_REPORT_3.md`
- Implementation context: `AUDIT_CONTEXT.md`
- Architecture/verification handoff: `HANDOFF.md`
- Client requirements: `archive/wasted update.txt`
- Canonical docs: `docs/README.md`, `docs/backend/*`

## Ground rules

- Read-only: no code, SQL, config, generated asset, or database changes.
- Never trigger a real wipe/reset, install on a physical device, or attack a live service.
- Use the installed `security-audit` skill.
- Use OWASP Top 10 (current edition) and Android MASVS/MASTG as the security framework. Run safe
  dependency/secret/header scans and passive local checks; no active exploitation.
- Do not accept handoff claims as proof. Mark unexecuted checks **Unverified**.
- Any remaining High/Blocker or mandatory gate means **NOT PRODUCTION-READY**.

## Fixes to verify (source + runtime evidence)

### 1. P2P High — peer impersonation

- Peer leaf certificate SHA-256 is pinned during pairing; paired client/server TLS requires the
  pinned peer certificate; client certificates are required.
- Handshake device ID is bound to the verified TLS certificate, and every message's
  `fromDeviceId`/`toDeviceId` is checked before dispatch.
- Discovery must not overwrite a paired peer's pin; certificate mismatch must reject the connection.
- Verify pairing rotates/re-pairs safely, and hostile tests cover: arbitrary cert, spoofed device ID,
  mismatched handshake ID, mismatched message ID, unpaired cert, replay, legitimate pair/re-pair.
- Verify the P2P Room database is SQLCipher-encrypted and legacy plaintext rows are imported as
  unpaired (never trusting the old APK-signature hash as a TLS pin).
- Verify pairing PINs use `SecureRandom`, are single-use, and have an attempt lockout.
- Verify P2P logs do not expose peer names, IPs/ports, device/message IDs, or command identifiers.

### 2. Verifier negative proof

- `supabase/tests/verify_negative.sh` must run the **real** `verify.sql` against a disposable DB
  after: extra permissive policy, mismatched predicate/role/mode, and PUBLIC default-function drift.
- Each drift case must make `verify.sql` fail; the undrifted database must pass.
- Confirm exact policy table/name/cmd/roles/mode/predicate matching and effective default-ACL probe.
- If the harness cannot run, mark the finding **Unverified**, not Fixed.

### 3. Public signup/resource boundary

- Verify the live Auth configuration (MCP/dashboard): Confirm email, anonymous sign-ins, email
  signup state, rate limits, Site URL.
- Confirm the single-owner guard prevents a second usable dashboard account and does not break
  anonymous device sign-in.
- Decide whether the chosen guard is sufficient for resource abuse, or require disabling email
  signups after owner bootstrap / host access control; record the release decision.

### 4. Anti-framing deployment

- Verify the app-generated ZIP contains exactly `index.html` + `_headers` and no secrets.
- Verify deployed response headers (`frame-ancestors 'none'`, `X-Frame-Options: DENY`, nosniff,
  no-referrer) on the actual production URL and perform a benign framing test.
- Repository `_headers` alone is not deployment proof.

### 5. Remaining correctness/docs

- Sign In has no client-side 12-character minimum; Create Account retains it.
- Email filtering blocks whitespace/invalid chars, lowercases, deduplicates `@`, and handles paste;
  password fields preserve spaces and eye toggles do not submit.
- Notifications default ON everywhere; web tests currently 25/25; 14 migrations; cumulative update
  wording; manifest contents; Netlify provider behavior.
- Legacy stranded-command repair is idempotent and the linked project has zero stranded rows.
- Clipboard-retention warning is present.
- No P2P log identifiers or secrets in release/crash logs.

## Release evidence gates (mark Unverified if not run)

1. Fresh-project `setup.sql`; actual `verify.sql`; four SQL suites + verifier-negative harness;
   migration parity/diff; advisors; Free-plan/quota.
2. Upgrade replay from the previous schema through both new migrations, including legacy repair
   count/result/event count and idempotent second run.
3. Android 95/95, web 25/25, clean build/lint, signed-release certificate identity, dependency audit,
   tracked/history/APK secret scans, ZIP-content test, generated-artifact clean diff.
4. API 24/33/35/current target emulator matrix; foreground service, reboot, Doze, offline recovery,
   storage corruption/migration.
5. Two real devices: independent enrollment, reconcile, rename/revoke/re-enroll, commands, settings
   latency <500 ms, legitimate P2P pairing, and resistance to cert/ID spoof/replay.
6. Browser auth/confirmation/recovery/Site URL, paste/duplicate-`@`, keyboard/screen reader,
   offline/error, destructive dialogs, deployed anti-framing headers.
7. 16-hour Debug-ON zero-wipe soak, battery/load, release-log redaction, alerting/retention,
   backup/restore, and observed Supabase quota headroom.
8. Wipe E2E remains separately approval-gated.

## Report format (`AUDIT_REPORT_4.md`)

1. Verdict: **PRODUCTION-READY** or **NOT PRODUCTION-READY**.
2. Status of the P2P High, verifier-negative, public-signup, anti-framing, and Low findings.
3. OWASP Top 10 matrix with Pass/Fail/N/A, severity, evidence, minimum fix; Android MASVS notes.
4. New/residual findings by severity with minimal fixes.
5. Evidence gates executed vs Unverified, and exact missing evidence.
6. Requirements/behavior deltas and open product decisions.
7. Commands/scanners run and “no code changes made”.

Only return **PRODUCTION-READY** if the P2P identity fix, verifier-negative proof, signup decision,
deployed headers, and all mandatory release gates are closed.
