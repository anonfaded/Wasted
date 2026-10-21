# Security model

## Threat model

| Threat | Mitigation |
| --- | --- |
| Someone learns the dashboard URL/publishable key | Expected: key is public. RLS limits data; Auth rate limits mitigate signup abuse. CAPTCHA optional |
| Stolen owner password | Owner controls Supabase Auth; password never stored by the app/dashboard. Rotate password in Supabase |
| Stolen/revoked device | `revoke_device` rejects pending commands, terminalizes `executing` with an unknown-outcome result, and blocks reconciliation |
| Replay/duplicate command | Per-submission idempotency keys bound to action type/scope; server compare-and-set state transitions; local journal |
| Remote wipe bypass | Debug Mode re-read by `ResetExecutor`; remote Force Reset blocked while ON; only reset boundary |
| Someone learns an enrollment token | Token is single-use, 10-minute, hashed at rest; owner can issue a new one (old ones revoked) |
| Direct table tampering | No write policies/grants; writes only through SECURITY DEFINER RPCs |
| Secret key leakage | Secret/service-role keys are rejected by validation and never shipped; docs forbid them |
| Hosted dashboard contains secrets | False: the generated file contains only URL + publishable key |
| Clickjacking of destructive confirmations | Production hosts must send `frame-ancestors 'none'`/`X-Frame-Options: DENY`; the page also ships a frame-busting fallback |

## Key boundaries

| Key | Where it lives | Rules |
| --- | --- | --- |
| Project URL + **publishable** key | App config, generated dashboard | Public by design; safe to ship. RLS is the security boundary |
| **Secret/service-role** key | Never in app/dashboard/repo | Full data access, bypasses RLS; used only in trusted server-side tooling if ever needed |
| Supabase account password | User's account | Never stored by the app or dashboard |
| Database password | Supabase dashboard only | Never committed or embedded |
| Enrollment token | Generated in dashboard, pasted in app | Single-use, 10-minute expiry, hashed at rest |
| Android signing material | Local keystore (gitignored) | Never committed |

Validation rejects `sb_secret_...` and legacy `service_role` JWTs. The dashboard contains only the
URL + publishable key.

## Database access

- RLS is enabled **and forced** on every remote table.
- `anon` has no access; `authenticated` has select-only grants.
- All writes go through SECURITY DEFINER RPCs that check owner/active-device identity.
- An anonymous device cannot see owner tables or other devices; it can only reconcile/transition
  its own commands.
- Owners are normal non-anonymous users; devices are anonymous users bound by enrollment.

## Destructive boundary

- `ResetExecutor` is the **only** path to `DeviceAdminManager.wipeData()`.
- Debug Mode defaults ON; `ResetExecutor` re-reads the encrypted preference at entry and immediately
  before the wipe call. Missing/corrupt/read error is treated as ON.
- Remote Force Reset is blocked while Debug Mode is ON (`debug_blocked`), with a local notification.
- Force Reset executes at most once; interrupted `executing` commands are failed, never replayed.
- Per-device Debug Mode OFF requires owner action and supersedes pending Force Resets.

## Anonymous device identities

- Enabling anonymous sign-ins does **not** make the owner account anonymous. Owner accounts remain
  normal email/password accounts; the provider is used only to create per-device identities.
- An anonymous identity alone grants no app data. RLS/RPCs deny access until a device is bound to an
  owner account through a single-use enrollment token.
- The enrollment token is generated only by the signed-in owner, stored hashed, expires after 10
  minutes, and is consumed by one device.
- Abuse is limited by Auth rate limits (use 10 anonymous/hour/IP), daily cleanup of unbound
  identities older than 24 hours, and cleanup of identities for devices revoked for more than 30
  days. CAPTCHA is an optional additional control.
- The publishable key is public by design; it identifies the project but does not authorize data
  access.

## Device lifecycle

- **Revoke** immediately stops commands for that device and hides it from the dashboard's active
  list. It does not wipe the device. The device row is kept for audit history.
- Thirty days after revocation, the daily cleanup deletes only the anonymous Auth identity. The
  device row remains, with `auth_user_id` set to null; it is not silently deleted.
- A revoked installation cannot re-enroll with the same installation ID. On the device, use
  **Reset enrollment** (which rotates the installation ID), then claim a new token.

## Dashboard exposure

- The generated dashboard is public at its URL; anyone can attempt signups (rate-limited).
- RLS prevents access to another account's data.
- The publishable key is not a secret; do not treat the dashboard URL as one either.
- CAPTCHA for anonymous sign-ins is optional (Supabase recommends it); the client did not request
  it. Rate limits remain the abuse control.

## Secrets hygiene

- Never commit `.env`, keystores, database URLs/passwords, secret keys, signing material, tokens,
  dumps, or real account/device data.
- `.env.example` contains names only; `keystore.properties.example` has placeholders.
- APK scan: no real publishable/secret key, JWT material, project ref, or project URL is embedded
  (the app is unconfigured by default).

## Reporting a security issue

Do not open a public issue with exploit details. Contact the maintainer privately and include a
reproduction. Rotate any exposed key immediately in the Supabase dashboard.
