# Security model

## Threat model

| Threat | Mitigation |
| --- | --- |
| Someone learns the dashboard URL/publishable key | Expected: key is public. RLS limits data; Auth rate limits mitigate signup abuse. CAPTCHA optional |
| Stolen owner password | Owner controls Supabase Auth; password never stored by the app/dashboard. Rotate password in Supabase |
| Stolen/revoked device | `revoke_device` rejects pending commands, terminalizes `executing` with an unknown-outcome result, and blocks reconciliation |
| Replay/duplicate command | Per-submission idempotency keys bound to action type/scope; server compare-and-set state transitions; local journal |
| Remote wipe bypass | Debug Mode re-read by `ResetExecutor`; remote Force Reset blocked while ON; only reset boundary |
| Someone learns an enrollment token | Token is single-use, 10-minute, hashed at rest; open tokens are independent, so revoke unused ones explicitly if needed |
| Direct table tampering | No write policies/grants; writes only through SECURITY DEFINER RPCs |
| Secret key leakage | Secret/service-role keys are rejected by validation and never shipped; docs forbid them |
| Hosted dashboard contains secrets | False: the generated file contains only URL + publishable key |
| Clickjacking of destructive confirmations | Use the full app package (`index.html` + `manifest.webmanifest` + `sw.js` + `icons/` + `_headers`) on a header-capable host, or configure `frame-ancestors 'none'`/`X-Frame-Options: DENY`; the page also ships a frame-busting fallback |

## Confirmation email

- Supabase Auth sends the confirmation email; the dashboard does not build email HTML, run SMTP,
  or handle confirmation tokens.
- The email address is normalized and validated again by Supabase. The account name is stored as
  metadata/display text, never interpolated into dashboard HTML (`textContent` only).
- `emailRedirectTo` is derived only from the current origin and pathname and must be allowlisted in
  Supabase URL Configuration; this prevents arbitrary redirect targets.
- The dashboard does not consume implicit-flow fragments (`detectSessionInUrl: false`) and removes
  `access_token`/`refresh_token` fragments from the address bar and history on load. CSP and
  `Referrer-Policy: no-referrer` limit token/referrer exposure.
- Signup and resend responses use generic messages for existing emails so the dashboard does not add
  another account-enumeration channel. Supabase Auth rate limits remain the server-side control.
- Supabase’s built-in email service only sends to project team members and is limited to 2 emails/hour.
  Configure custom SMTP under **Authentication → Emails → SMTP Settings** before using a
  non-team owner email; otherwise the confirmation email will not be delivered.
- If you customize the Supabase email template, HTML-escape any custom metadata such as the account
  name; the default template does not include it.

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

## Auth input handling

- Emails are trimmed and lowercased before Supabase Auth; the dashboard uses `type=email`,
  `maxlength=254`, and explicit inline validation for empty or malformed values. Supabase validates
  again server-side.
- Passwords are never trimmed or altered. Create Account requires a confirmed password and at least
  12 characters; Sign In accepts existing passwords, including shorter ones if the project permits
  them. Configure the project's minimum password length if you need a server-side floor as well.
- Account names are display names: 1–32 characters, spaces and normal punctuation allowed,
  control characters rejected. They are stored in `public.accounts`; the signup copy is also stored
  in auth metadata as a bootstrap fallback. Device names are 1–80 characters.
- Dynamic values are rendered with `textContent`, not HTML interpolation; RPC parameters are
  parameterized and RLS/RPC ownership checks remain the authorization boundary.

## Single-owner guard

- Only the first authenticated owner can initialize a dashboard account. Additional Auth users can
  exist but cannot access an account, so public email signups cannot create a usable dashboard.
- Create the owner account before sharing the dashboard URL: the first authenticated user wins the
  bootstrap. Disabling email signups after bootstrap or host access control are optional additional
  controls; Confirm email is not a signup restriction.

## P2P peer authentication

- Each device has a persisted self-signed TLS certificate. Pairing pins the peer leaf certificate
  SHA-256; paired connections require the same certificate and the server requires a client
  certificate.
- The authenticated handshake binds the certificate to one device ID; every message must match that
  ID and the local recipient before dispatch. A changed certificate is rejected and requires
  re-pairing.
- The P2P Room database is SQLCipher-encrypted with a separate Tink-wrapped passphrase. Legacy
  plaintext peer rows are imported as unpaired rows so an old APK-signature hash is never trusted as
  a TLS pin.
- Pairing PINs use `SecureRandom`, are single-use, and have an attempt lockout.

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
