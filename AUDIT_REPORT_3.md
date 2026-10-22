# Wasted Remote v3.0.0 — Final Production & Security Audit

**Audit date:** 2026-10-22  
**Revision/worktree reviewed:** `03cd360b69f3f44a6cfc69f30f0ebbfc623c4f65`, plus the current pre-existing dirty worktree  
**Method:** read-only static audit of the current Android, P2P, web, SQL, generated-release, and documentation surfaces. Only this report was created. No project build/test script, database, deployed site, emulator, device, install, or wipe path was executed.

## 1. Verdict

**NOT PRODUCTION-READY.**

The audit found a new **High** P2P authentication bypass. Any same-LAN client can present an arbitrary TLS certificate and self-assert the ID of an already-paired peer. The receiver preserves that peer's paired state, does not bind the message identity to the TLS peer, and authorizes settings/reset messages only by the message-supplied device ID. Under the documented normal production condition of Debug Mode OFF, this can reach the factory-reset boundary; remote reset confirmation is OFF by default.

The final gate also remains blocked because:

- R2-M1's verifier logic is materially improved, but its negative test does not run `verify.sql` and prove the verifier fails for the required drift cases.
- The single-owner guard prevents a second application owner, but public Auth signup can still consume the self-hoster's MAU/database budget and the live Auth/rate-limit configuration was not observed.
- Anti-framing is correctly packaged in source, but no deployed response/header/framing evidence exists.
- The linked-project repair query and all required build, SQL, browser, emulator, real-device, soak, quota, signing, and artifact gates remain Unverified.

No P0/P1 release may proceed while the High P2P defect or any mandatory release-evidence gate remains open.

## 2. AUDIT_REPORT_2 finding status

| Finding | Status | Current evidence |
| --- | --- | --- |
| **R2-M1 — verifier proves tenant isolation** | **Partial / Open** | `supabase/verify.sql:20-53,87-105` defines and compares the exact table/name/command/roles/mode/predicate policy set and rejects extras. `:175-205` checks catalog defaults and creates an effective function-ACL probe. However, `supabase/tests/remote_verify_drift_test.sql:17-69` copies portions of the verifier logic and directly asserts the effects; it never executes `verify.sql` and requires it to fail. Its ACL case grants PUBLIC and observes the grant (`:61-68`), rather than removing the required explicit global deny and proving `verify.sql` fails. The mandated negative proof is absent. |
| **R2-M2 — public-signup control** | **Partial** | The serialized single-owner bootstrap is sound in source: an authenticated non-anonymous user returns its existing account or takes an advisory transaction lock and is rejected if any account exists (`supabase/migrations/20261021150306_remote_single_owner.sql:16-32`). Anonymous identities are rejected only from owner initialization (`:19-21`), so device anonymous Auth remains available. `supabase/tests/remote_rpc_test.sql:51-84` contains first-owner/idempotence/anonymous/second-owner cases. Extra Auth users are inert at the application layer but can still consume finite Auth/MAU resources; the live email/anonymous provider, Confirm email, Site URL, rate limits, CAPTCHA, and signup state were not observed. |
| **R2-L1 — sign-in password policy** | **Fixed** | Sign In has no `minlength` (`web/index.html:34-45`); Create Account retains 12 characters (`:62-84`). The submitted password is not trimmed or transformed (`web/src/auth.js:65-77,124-141`). |
| **R2-L2 — legacy stranded commands** | **Partial (fixed in source; live state Unverified)** | The forward-only repair changes only `executing` commands on revoked devices to `failed/device_revoked_during_execution`, inserts one conflict-safe failure event, removes client execution, and runs once (`supabase/migrations/20261021150716_remote_legacy_revocation_repair.sql:5-38`). The idempotence/result/event-count regression is present at `supabase/tests/remote_rpc_test.sql:933-965`. The required linked-project query for pre-existing stranded rows and observed upgrade execution were not performed. |
| **R2-L3 — documentation consistency** | **Partial** | Token independence, 14 migrations, and manifest contents now agree, but three contradictions remain. The current tree has **23** web `test(...)` declarations, while HANDOFF/canonical verification docs claim 22; these are static declarations, not pass evidence. `docs/architecture.md:94-99` says notifications default OFF while source, README, and handoff say ON. `supabase/build-setup-sql.mjs:104-112` still generates “stepwise” bundle headers while its generation and generated README define direct cumulative upgrades (`:148-163,219-235`). Netlify behavior is external provider behavior, not a repository guarantee; current official documentation supports temporary protection for anonymous Drop deployments, but the exact outcome after claim depends on plan/settings. |
| **R2-L4 — clipboard warning** | **Fixed** | The visible token panel warns that copies remain in OS clipboard/history and advises overwriting (`web/index.html:355-368`); the generated Android dashboard template carries the same warning. |

### Anti-framing deployment

**Fixed in source/package; production Unverified.** `web/_headers:1-6` and the byte-identical APK asset set `frame-ancestors 'none'`, `X-Frame-Options: DENY`, `nosniff`, `no-referrer`, and a restrictive Permissions Policy. The wizard writes exactly `index.html` and `_headers` into the ZIP (`RemoteSetupActivity.kt:361-385`), and the UI recommends it for header-capable hosts (`activity_remote_setup.xml:361-374`). No production URL, actual response headers, or benign framing observation was supplied, so repository files are not deployment proof.

## 3. OWASP Top 10 matrix

The current framework is **OWASP Top 10:2025**, not the 2021 numbering reproduced in the audit prompt. In 2025, SSRF is folded into A01; supply-chain failures are A03; cryptographic failures are A04; injection is A05; and A10 is mishandling exceptional conditions. The requested legacy checks are retained under their current categories. Reference: <https://top10.owasp.org/>.

| OWASP 2025 category | Result | Severity | Evidence and minimum action |
| --- | --- | --- | --- |
| **A01 Broken Access Control** | **Fail** | **High** | P2P TLS accepts every client/server certificate (`SecurityManager.kt:59-73,178-232`). The cleartext-in-TLS handshake supplies an unverified device ID/name/hash, overwrites the stored certificate hash, and preserves `pairedAt` for the claimed ID (`MessageServer.kt:124-153`). Messages are not checked against that connection identity (`:173-195`); authorization only looks up `message.fromDeviceId` and tests `pairedAt > 0` (`P2PController.kt:245-255`). A same-LAN client can therefore impersonate a paired peer. Minimum fix: pin the peer certificate/public key captured during authenticated pairing; require and verify client certificates; bind handshake ID and every message ID to that verified peer before any database update or dispatch; add spoof/replay/rotation tests. SQL access control is strong in source—FORCE RLS, SELECT-only grants, authenticated SECURITY DEFINER RPCs, and tenant/device policies—but live execution/parity remains Unverified. No server-side fetch surface was found; optional/browser URLs are HTTPS-restricted (`web/src/main.js:84-126`). |
| **A02 Security Misconfiguration** | **Fail** | Medium | Deployment Auth/CORS/rate limits, email and anonymous providers, Site URL, actual hosting headers, advisors, and quotas are outside repository proof. Public signup remains available in the documented flow and may consume free-tier resources despite the inert second-owner guard. P2P calls itself mutual TLS while accepting arbitrary certificates. Enforce peer trust as above, decide and enforce the post-bootstrap email-signup/host-access policy, and capture the live settings/header/advisor evidence. |
| **A03 Software Supply Chain Failures** | **Partial / Unverified** | Low | Direct web packages are exactly pinned and lock entries have integrity fields (`web/package.json:13-18`; `web/package-lock.json`). The lock root still says version 2.0.0 while the package is 3.0.0 (`web/package-lock.json:1-15`). The Gradle wrapper uses HTTPS and URL validation but lacks `distributionSha256Sum` (`gradle/wrapper/gradle-wrapper.properties:1-7`). No authoritative complete npm/Gradle transitive-CVE scan was executed. Regenerate lock metadata, pin the wrapper checksum, and run/retain approved dependency scans before release. |
| **A04 Cryptographic Failures** | **Fail** | **High** | Remote secrets/sessions and certificate private keys use Tink/Android Keystore; the remote journal uses SQLCipher (`RemoteDatabase.kt:35-72`). However, P2P transport provides encryption without authenticated peer identity because its trust manager is allow-all. The P2P Room database is plaintext (`WastedP2PDatabase.kt:33-42`) and stores peer identity, IP, certificate hash, and pairing state (`Peer.kt:11-23`), contrary to the project's encrypted-Room requirement. Migrate the P2P database to SQLCipher with a separately generated Tink-wrapped passphrase and authenticated certificate binding. The unused `SecurityManager.encryptSecret/decryptSecret` methods are Base64 placeholders (`SecurityManager.kt:77-107`) and should be removed or replaced before use. |
| **A05 Injection** | **Pass (static)** | None found | Production SQL uses typed parameters; no user-derived dynamic SQL was found. Dashboard rendering uses `textContent`/DOM construction rather than `innerHTML` (`web/src/main.js:702-710`; `web/src/ui.js`). CSP limits connections to HTTPS/WSS Supabase hosts (`web/index.html:7-8`). Preserve these patterns and prove them in browser tests. |
| **A06 Insecure Design** | **Fail** | Medium | Pairing uses a six-digit PIN generated with repeated `java.util.Random()` construction and has no attempt counter/cooldown (`PairingManager.kt:43-88`). The stronger certificate/identity bypass makes the PIN irrelevant after a peer ID is known. Public Auth signup also lacks a source-enforceable resource-abuse boundary. Use `SecureRandom`, one-time consumption, strict failed-attempt limits/cooldown, certificate-bound pairing, and an explicit post-bootstrap signup/access-control policy. Destructive cloud commands retain typed confirmation and Debug Mode guards, which are positive controls. |
| **A07 Authentication Failures** | **Fail** | **High** | Browser owner Sign In/Create Account separation, `emailRedirectTo`, pending handle recovery, persisted refresh, sign-out, and anonymous device identity are coherent in source (`web/src/auth.js:65-159`; `web/src/supabase-client.js:10-17`). Live Confirm email/password/rate-limit/provider settings are Unverified. P2P authentication is defeated by arbitrary certificates plus self-asserted IDs. Fix P2P identity binding and capture live Auth configuration. |
| **A08 Software or Data Integrity Failures** | **Partial / Unverified** | Medium | Release signing is fail-closed and unsigned outputs are labeled (`app/build.gradle:68-102`). Fourteen migrations match `releases.json`; the three setup copies hash to `2042ef…4cb`, the two verifier copies hash to `6724b7…1f7c`, and both match `manifest.json:4-5`. The signed APK certificate, APK/source secret scans, build provenance, generated clean diff, upgrade replay, and actual package ZIP have not been observed. Complete those gates and add ZIP-entry and generator-contract tests. |
| **A09 Security Logging and Alerting Failures** | **Fail** | Low | SQL command events provide lifecycle auditability. Android P2P logs expose peer names, IP endpoints, stable device/message identifiers, and command types (`MessageQueue.kt:37-69`; `P2PNetwork.kt:211-258`; `DeviceDiscovery.kt:146-170`). Release minification is disabled (`app/build.gradle:38-41`), so those calls remain. Redact or pseudonymize identifiers/endpoints, gate diagnostic logs, and verify release logcat/crash payloads and retention. |
| **A10 Mishandling of Exceptional Conditions** | **Partial / Unverified** | Medium | Reset execution fails closed on missing/corrupt Debug Mode and rechecks immediately before `wipeData()` (`ResetExecutor.kt:26-82`). Remote network code generally catches failures, but malformed/unbounded P2P identity and message input has no authenticated boundary and no demonstrated size/rate controls. Browser/offline/error, database drift failure, corrupt storage, retry, and Doze/reboot behavior were not executed. Add bounded input/rate limits and execute the failure-path matrix. |

### Android MASVS/MASTG spot-check

- **Storage — Fail:** remote preferences/journal are encrypted, but `wasted_p2p.db` is plaintext.
- **Crypto — Fail:** TLS 1.2+ is configured, yet trust-all verification defeats authenticity; Base64 helpers are mislabeled encryption.
- **Auth — Fail:** peer identity is self-asserted and not certificate-bound; PIN entropy/attempt handling is weak.
- **Network — Fail:** encrypted channel, unauthenticated endpoint; no hostname or peer pin verification.
- **Platform — Pass in source / runtime Unverified:** backup is disabled and sensitive services are non-exported or platform-permission protected; Device Admin and ResetExecutor boundaries remain present.
- **Code quality/resilience — Partial:** Debug Mode is fail-closed and reset errors are contained, but P2P parsing/authentication lacks hostile-input tests and bounded abuse controls.

## 4. New and residual findings

### Blocker

None separately classified. The High finding and mandatory evidence gaps are release-blocking.

### High — unauthenticated LAN peer can impersonate a paired device

**Boundary/result.** A lower-trust same-LAN client can complete TLS with any certificate, claim an arbitrary handshake identity, then send a message whose `fromDeviceId` names an already-paired peer. The receiver replaces that peer's advertised certificate hash while keeping its nonzero `pairedAt`, and dispatches settings or reset solely from the message-supplied ID. This fully defeats the explicit paired-peer authorization control.

**Impact.** `SETTINGS_CHANGE` can alter wipe/trigger/confirmation settings (`SettingsSyncManager.kt:269-295`). `RESET_COMMAND` is dispatched to `RemoteControlManager` (`P2PController.kt:245-255`); confirmation is OFF by default (`Preferences.kt:128-130`), causing immediate reset execution (`RemoteControlManager.kt:132-142`). The final Debug Mode check still blocks destruction while Debug Mode is ON (`ResetExecutor.kt:46-65`), so wipe requires the normal production state of Debug Mode OFF plus supported/active reset capability. The defect also permits non-destructive unauthorized settings changes regardless of wipe readiness.

**Minimum fix.** During PIN-authenticated pairing, store the peer leaf/public-key fingerprint—not an APK-signature string supplied by the peer. Configure mutual TLS to require a client certificate; verify the presented peer key against the pinned record; bind the verified certificate to exactly one device ID; reject handshake/message ID mismatch before updating Room or calling `onIncomingMessage`; define safe certificate rotation/re-pairing; add same-LAN spoof, replay, mismatched-ID, unpaired-cert, and legitimate-pair regression tests. Use `SecureRandom` and limit pairing attempts.

### Medium — R2-M1 negative verifier proof is incomplete

The production verifier's exact-set logic appears correct statically, but the mandated negative test tests a duplicate query rather than the production verifier. That can pass after future verifier regressions. Replace the copied assertions with a transaction-scoped harness that introduces each required drift, invokes the actual `verify.sql` entry path, and asserts failure: extra permissive policy, mismatched predicate/role/mode, and removal of the explicit global default ACL. Then restore/rollback and prove the undrifted verifier passes.

### Medium — public Auth signups can still consume the self-hoster's free tier

The database guard stops a second owner row, so this is not a cross-tenant authorization bypass. It does not stop distributed creation of Supabase Auth users. The setup intentionally exposes Create Account and relies on manually configured provider/rate-limit settings. Decide and enforce one release policy: disable email signup after bootstrap, require host access control/invitation, or otherwise enforce the one-owner resource boundary. Preserve anonymous device sign-in and validate actual usage thresholds.

### Medium — P2P Room data is not encrypted

`WastedP2PDatabase` uses ordinary Room with no SQLCipher factory (`WastedP2PDatabase.kt:33-42`) while `Peer` persists local-network and pairing metadata (`Peer.kt:11-23`). This directly violates the mandatory “all device data … Room with encryption” requirement. Use the existing remote database pattern: SQLCipher plus a distinct random passphrase stored through Tink/Keystore, with a tested forward migration and no plaintext fallback.

### Low — email insertion rule and regression coverage remain incomplete

`beforeinput` blocks/sanitizes ordinary typed insertions, but returns when `event.data` is null (`web/src/auth.js:29-45`), which occurs for some paste/input paths. The fallback normalization removes invalid characters and whitespace but does not deduplicate `@` (`:161-186`). Native email validity should stop submission, but it does not satisfy “duplicate `@` blocked before insertion, paste handled.” None of the 23 static test declarations covers the auth DOM controller. Sanitize the complete prospective value for every insertion/paste/input path, enforce at most one `@`, and add DOM/browser tests for typing, selection replacement, paste, lowercase, whitespace, password spaces, and non-submitting eye toggles.

### Low — documentation/generator statements still conflict

- Notifications: `docs/architecture.md:94-99` says default OFF; source defaults ON (`RemoteCredentialStore.kt:62-64`) and README/HANDOFF say ON.
- Updates: `supabase/build-setup-sql.mjs:104-112` generates stepwise instructions; the same generator creates a cumulative bundle from every prior release and says no intermediates are needed (`:148-163,219-235`).

Correct both before using the docs/generated bundle as a release contract.

### Low — P2P logs retain unnecessary device/network identifiers

Redact peer names, device/message IDs, and IP/port details from production logs; retain event class, safe result, and latency/correlation values that cannot identify devices. Verify release logcat and crash reporting with representative failures.

## 5. Production gates

### Executed in this audit

- Static source trace of all R2 findings, OWASP categories, and Android MASVS concerns.
- Counted 14 migration files and confirmed the 14 names in `supabase/releases.json:7-22`.
- Counted 23 web `test(` declarations and 92 Android `@Test` declarations. These are counts, **not pass results**; the documentation's web 22/22 claim is stale.
- SHA-256 compared root/release/APK setup SQL, root/release verifier SQL, and web/APK header assets; the SQL hashes match `supabase/releases/3.0.0/manifest.json:4-5`.
- Read-only tracked-filename/secret-pattern review found no embedded real project URL/key/account/device data. Existing local secret-like files were not opened or copied into this report.
- Reviewed pinned dependency declarations and lock/wrapper metadata. Web/Gradle transitive vulnerability status remains Unverified.
- Checked current OWASP 2025 and current Netlify provider documentation. No deployed project/site was contacted.

### Unverified and release-blocking

1. **Database:** fresh-project `setup.sql`; actual `verify.sql`; schema, RLS, RPC, concurrency, and verifier-negative suites; migration parity/diff; advisors; linked Auth settings; linked query for legacy stranded commands; free-tier database/egress/MAU/Realtime/connection usage.
2. **Upgrade:** replay from the prior schema through both new migrations, including observed legacy repair count/result/exactly-one event and idempotent second run.
3. **Build/release:** Android 92/92 and current web-suite execution (23 declarations), clean build/lint, signed-release certificate identity, authoritative npm/Gradle dependency audit, tracked/history/rebuilt-APK secret scans, ZIP-content test, and generated-artifact clean diff. The pre-existing dirty worktree prevents an unqualified clean-diff claim.
4. **Android/emulators:** API 24/33/35 and current target; foreground service/notification; reboot, direct boot, Doze, offline recovery, storage migration/corruption, and P2P hostile-input/auth tests.
5. **Real devices:** two-device independent enroll, reconcile, rename, revoke/re-enroll, commands, settings latency below 500 ms, legitimate P2P pairing, and resistance to cert/ID spoof and replay.
6. **Browser/deployment:** actual anti-framing/nosniff/referrer headers and benign framing check; auth confirmation/recovery/Site URL; email paste/duplicate-`@`; keyboard/screen reader; offline/error; destructive dialogs.
7. **Soak/operations:** 16-hour Debug-ON zero-wipe soak, battery/load, release-log redaction, alerting/retention, backup/restore, and observed Supabase quota headroom.
8. **Wipe:** real wipe E2E remains separately approval-gated and was not attempted.

The security-audit execution policy requires project-controlled code to run with no external network, an empty allowlisted environment, a read-only target/toolchain, scratch-only writes, and explicit resource/wall-clock limits. That OS-enforced sandbox was not available, so project tests/builds were not run and handoff claims were not accepted as evidence.

## 6. Requirements and behavior deltas

- **P2P as an addition:** preserved in product structure, but its current authentication violates the requirement that all device communication be securely encrypted/authenticated and makes the existing P2P regression gate fail statically.
- **Device Admin/minSdk:** Device Admin remains present; no feature removal was found. Runtime API 24–current compatibility is Unverified.
- **Remote defaults:** remote management remains unconfigured/off by default and source validation is HTTPS-only; runtime zero-request behavior was not observed.
- **Owner model:** explicit Create Account remains a documented deviation from the archived “auto-create if feasible” wording. The client must formally accept it.
- **Notifications:** source default is ON, but one canonical architecture section still says OFF.
- **Enrollment:** independent one-time tokens are coherent in source/docs; real multi-device behavior is Unverified.
- **Update contract:** intended direct cumulative bundles are implemented, but the generated SQL header still says stepwise.
- **Netlify:** anonymous Drop protection/one-hour claim behavior is provider behavior and can vary after claim by plan/team visibility; it is not enforced by this repository. Official reference: <https://docs.netlify.com/start/quickstarts/netlify-drop-quickstart/>.

## 7. Open product decisions that block release

1. Choose and enforce the authenticated P2P identity model: pinned per-device certificate/public key, binding and rotation/re-pairing rules. This is not optional hardening; it is required to close the High finding.
2. Choose the post-owner-bootstrap public signup/resource policy while preserving anonymous device sign-in.
3. Formally accept or reject explicit Create Account versus the archived auto-create preference.
4. Define the release requirement for backup/restore evidence and operational security monitoring/retention.

Anti-framing packaging and cumulative upgrades no longer need product decisions; they need deployment/test evidence and removal of the remaining contradictory generator text.

## 8. Commands/scanners and change boundary

Representative read-only commands: `git status --short`, `git rev-parse HEAD`, `git ls-files`, `rg`, `find`, `sed`, `nl`, `wc`, `shasum -a 256`, and byte/content comparisons. Authoritative web lookups were limited to OWASP, PostgreSQL semantics, Netlify provider behavior, and dependency-vulnerability searches. No scanner output was treated as proof; no complete current CVE result was available without an approved package/dependency audit.

Not run: Gradle, Node project scripts/tests, `npm audit`, Supabase CLI/MCP/SQL, ZAP, browser automation, APK tooling, emulator, ADB, physical devices, live endpoints, installs, or destructive commands.

**No code, SQL, configuration, generated asset, canonical documentation, remote system, or device was changed. The only file created by this audit is `AUDIT_REPORT_3.md`; no commit was created.**
