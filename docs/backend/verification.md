# Verification

Run these before claiming a release is ready. Docker is only needed for schema diff/replay.

## Build and tests

```bash
./gradlew :app:testDebugUnitTest :app:assembleDebug
./gradlew :app:assembleRelease
cd web && npm test && npm run build && npm run build:android-template
```

Expected: Android **92/92** unit tests (or the current count), web **19/19**, both APKs build, and
the release APK is signed with the expected certificate.

## Generated artifacts

```bash
node supabase/build-setup-sql.mjs
git diff --exit-code supabase/ app/src/main/assets/
```

Expected: setup SQL, release folder, update bundles, and manifests are current; a migration or
`releases.json` change without regeneration fails this check. Gradle runs the generator automatically
before asset merging.

## Backend parity (Docker + linked project)

```bash
./gradlew :app:verifyRemoteSchema     # supabase db diff --linked → must print no changes
supabase migration list --linked      # no local-only/remote-only versions
```

## SQL suites

Run each file in `supabase/tests/` against the linked database inside a transaction; they end with
`rollback;` so nothing persists.

Expected: schema, RLS, RPC, and concurrency suites pass (4/4).

## Fresh install

1. Create an empty Supabase project.
2. Run `supabase/releases/<current>/setup.sql`.
3. Enable anonymous sign-ins, disable Confirm email.
4. Run `verify.sql` → all PASS.
5. Run the four SQL suites.
6. Generate the dashboard, create an owner, enroll a device.

## Upgrade path

1. Apply the **previous** release's `setup.sql` to an empty project.
2. Apply the current release's `update-from-<previous>-to-<current>.sql`.
3. Run `verify.sql` and the SQL suites.
4. `db diff --linked` must be empty.

## Security scans

```bash
git grep -nE 'sb_secret_[A-Za-z0-9]|service_role|BEGIN [A-Z ]*PRIVATE KEY|postgres(ql)?://[^ ]+:[^ ]+@'
unzip -p app/build/outputs/apk/release/Wasted-v*.apk 'classes*.dex' | strings \
  | grep -E 'sb_publishable_[A-Za-z0-9_-]{16,}|eyJ[A-Za-z0-9_-]{30,}|https://[a-z0-9]+\.supabase\.co'
```

Expected: only validator/test constants in source; no real key/URL in the APK.

## Regression areas (must remain green)

- Master enable/disable and Device Admin removal.
- Panic Kit, tile, shortcut, broadcast, notification, lock, USB, and application triggers.
- LockJob schedule/cancel/reboot and timer reporting; local settings changes while the service runs.
- Device Admin reset tiers and Shizuku/manual reset paths.
- P2P discovery, pairing, TLS, settings sync, reset confirmation, identity.
- Foreground service with Lock/USB only, P2P only, remote only, combinations, and none.
- Direct boot/user unlock/package replacement and encrypted preference migration/corruption.
- Remote disabled/unconfigured/offline: zero network work and unchanged local behavior.
- Remote/P2P independent toggling.

## Open gates

- Emulator matrix (API 24/33/35): lifecycle, Doze, offline/socket loss, restart/reboot.
- ≥16-hour soak with Debug Mode ON; prove Force Reset is blocked and wipe count is zero.
- Instrumentation/log-redaction and browser/a11y suites.
- Docker clean replay (`supabase db reset` + `db diff --linked`).
- Fresh-project setup and upgrade-path replay; Usage/Realtime report capture.
- Real wipe E2E only on an emulator/sacrificial device with explicit approval.

More: [migrations-and-releases.md](./migrations-and-releases.md) ·
[release-checklist.md](./release-checklist.md) · [database.md](./database.md) ·
[remote-protocol.md](./remote-protocol.md)
