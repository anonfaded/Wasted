# Wasted (Modded v3.0.0)

**This is a modded version of [Wasted](https://github.com/x13a/Wasted)** — the original open-source emergency lock & factory reset app by [@x13a](https://github.com/x13a).

## What's New in This Fork

- **P2P Network**: Remote factory reset via encrypted local Wi-Fi (TLS encrypted messaging on port 9876)
- **Android 14+ Device Owner Setup**: Interactive Shizuku-based setup to make Wasted Device Owner for full factory reset capability
- **Android 14+ Reset**: On Android 14+, eligible Device Owner installs use `wipeDevice()`; non-Device-Owner installs use the existing best-effort chain (Shizuku + manual cleanup). Android <14 uses the legacy `wipeData()` path. Debug Mode gates every path.
- **Debug Mode**: Enabled by default. While enabled, dangerous commands never execute — they are logged locally, and remote commands are shown as a notification stating they were received but not executed. Disable it locally with a danger confirmation to allow real wipes.

All original features remain unchanged and fully compatible with Android 7+.

---

> [!WARNING]
> This is a modded version. For the original app, see [x13a/Wasted](https://github.com/x13a/Wasted).

Lock a device and wipe its data on emergency.

[<img 
     src="https://fdroid.gitlab.io/artwork/badge/get-it-on.png"
     alt="Get it on F-Droid"
     height="80">](https://f-droid.org/packages/me.lucky.wasted/)
[<img 
      src="https://play.google.com/intl/en_us/badges/images/generic/en-play-badge.png" 
      alt="Get it on Google Play" 
      height="80">](https://play.google.com/store/apps/details?id=me.lucky.wasted)

<img 
     src="fastlane/metadata/android/en-US/images/phoneScreenshots/1.png" 
     width="30%" 
     height="30%">

You can use [PanicKit](https://guardianproject.info/code/panickit/), tile, shortcut or send a 
message with a secret code. On trigger, using 
[Device Administration API](https://developer.android.com/guide/topics/admin/device-admin), it 
locks a device and optionally runs wipe (factory reset). Or it can send a broadcast message 
instead of the wipe.

Also you can:
* fire when a device was not unlocked for X time
* fire when a USB data connection is made while a device is locked
* fire when a fake messenger app is launched
* fire when a duress password is entered (companion app: [Duress](https://github.com/x13a/Duress))

The app works in `Work Profile` too, but with limitations. Use it to install risky apps and 
`Wasted` in it. Then you can wipe this profile data with one click without wiping the whole device.

For base security take a look at: [Sentry](https://github.com/x13a/Sentry).  
Only encrypted device may guarantee that the data will not be recoverable.

Be aware that the app does not work in _safe mode_.

## Remote Management

This fork adds optional remote management through your own Supabase project. It is disabled by default and performs no network work until it is configured, enrolled, and enabled. Full backend documentation is indexed in [`docs/README.md`](docs/README.md); the six-step setup is [`docs/backend/quickstart.md`](docs/backend/quickstart.md).

### Backend setup

1. Create a free Supabase project and open **SQL Editor**.
2. Paste `supabase/setup.sql` and press **Run** once. It creates the tables, RLS policies, RPCs, grants, Realtime publication, and cleanup job. No CLI or Docker is required.
3. In **Authentication → Providers**, enable **Allow anonymous sign-ins** (per-device identities) and leave **Confirm email** enabled (recommended: click the link in the email, then sign in). In **Authentication → Rate Limits**, set anonymous sign-ins to 10/hour/IP and sign-in/sign-up to 10 per 5 minutes/IP (or verify your chosen values). CAPTCHA is optional.
4. Run `supabase/verify.sql`; every row should say PASS.
5. The app setup wizard provides the same SQL and instructions. Developers can instead use the CLI/MCP path documented in `supabase/README.md`.

The app and dashboard store only the project URL and a publishable key. Never use a secret or service-role key.

### Android setup

1. Open **Remote Management** and use **Open setup wizard** (or enter the project URL, publishable key, and dashboard URL manually); save the configuration.
2. In the dashboard, create an enrollment token (valid 10 minutes).
3. Enable Remote Management (this forces Debug Mode ON), enter the token, and claim it. The device appears in the dashboard after the first sync.

### Hosting the dashboard

The dashboard file is generated **by the app**, already configured with your own Supabase project URL and publishable key. There is no file editing and no dashboard server: the page talks directly to your Supabase project over HTTPS/WSS.

1. In the app: **Remote Management → Open setup wizard**.
2. Create a free Supabase project, then paste its **Project URL** and **publishable key** into the wizard.
3. In Supabase, open **SQL Editor**, run the setup SQL copied from the wizard, then under **Authentication → Providers** enable **anonymous sign-ins** and leave **Confirm email** enabled. Anonymous sign-ins give each device its own private identity, so your email/password is never stored on the device. Confirm email is recommended: click the link in the email, then sign in. If you do not want Remote Management, you can leave anonymous sign-ins off; the rest of the app and the dashboard still work, but devices cannot enroll or sync. Under **Authentication → Rate Limits**, set anonymous sign-ins to 10/hour/IP and sign-in/sign-up to 10 per 5 minutes/IP (or verify your chosen values). CAPTCHA is optional.
4. In the wizard, **generate the dashboard file** and save it as `index.html`, or use **Save
   deployable package (.zip)** when the host should send strict framing headers (`index.html` +
   `_headers`). Netlify Drop requires an `index.html` home page; another filename shows “page not
   found.”
5. Host it: drag the file onto **Netlify Drop** (no account needed to start). Netlify Drop
   currently password-protects the temporary site and expires it after **1 hour** until you click
   **Claim this site** and sign in or sign up. Copy the final HTTPS URL, then set Supabase →
   **Authentication → URL Configuration → Site URL** to that URL so confirmation emails return to
   the dashboard. Alternatives: Cloudflare Pages direct upload, GitHub Pages, Vercel, any HTTPS
   static host.
6. Open the hosted URL, create your account, then paste that URL into Remote Management, Save, and
   Enable. Create an enrollment token in the dashboard and claim it in the app.

When updating an existing dashboard, replace `index.html` in the **same Netlify site**; creating a new
site changes the URL and requires updating Remote Management.

### Building the APK

`./gradlew assembleSignedRelease` (or `assembleDebug` for development) requires Node.js 20+. The
signed task fails unless `keystore.properties` and the keystore exist; unsigned release APKs are
named `Wasted-v<version>-unsigned.apk`. Gradle regenerates the dashboard template,
`supabase/setup.sql`, and the release update bundles from the tracked sources before packaging, so
the APK never contains stale assets; set `NODE_BIN`/`NPM_BIN` if Node is not on `PATH`. Developers
can verify the linked database against the migrations with `./gradlew :app:verifyRemoteSchema`
(requires Supabase CLI, Docker, and `supabase link`).

Release updates are organized by `supabase/releases.json`: each app release lists its cumulative
migrations and schema version, and the build emits a folder per release
(`supabase/releases/<version>/`) with `setup.sql`, cumulative update bundles, `verify.sql`, a
checksummed manifest, and generated apply instructions. There is no automatic update check; release
notes name the exact bundle to run after a backup.

No CORS setup or build step is needed at the host. With Confirm email enabled, set the Supabase Auth
**Site URL** to the hosted dashboard URL. Updating the dashboard means replacing `index.html` in the
same site; use the app's deployable ZIP when strict framing headers are required.

The publishable key is public by design and safe to expose. Never embed a secret/service-role key or the database password. The generated file contains no secret. Anyone who can open the hosted page can attempt to sign up, but only the first owner can initialize the dashboard; extra Auth users cannot access account data.

* Sign In and Create Account are explicit; a failed sign-in never creates an account. Confirm email is recommended and verifies ownership, but it is not a signup restriction.
* The page ships a restrictive CSP meta policy (`default-src 'none'`, Supabase-only connections, inline scripts/styles) and `no-referrer`. Meta policies cannot set `frame-ancestors`; production hosting must send `frame-ancestors 'none'` (or `X-Frame-Options: DENY`) via response headers. Use the app's deployable ZIP (`index.html` + `_headers`) on a header-capable host, or configure the headers there. The page also has a frame-busting fallback.

### Behavior and limits

* Device cards show reported state; Realtime only triggers a refetch and never executes payloads directly. A device counts as "recently connected" for 150 seconds; timers are extrapolated locally.
* Lock Timer / USB Trigger changes are revision-protected and apply to every enrolled device.
* Reset Timer restarts the lock timer. Force Reset sends a factory reset (typed confirmation in the dashboard) and only executes while Debug Mode is OFF.
* Debug Mode is ON by default and blocks destructive remote commands. The dashboard asks for confirmation in both directions; the device applies remote toggles without a local dialog. Turning it OFF expires after 10 minutes if the device stays offline, and supersedes any pending Force Reset.
* Local notifications (on by default, `remote_events` channel) cover settings applied, Reset Timer, Force Reset, blocked or failed commands, manual-sync success, and sync failures. Repeated notices replace each other instead of stacking, and heartbeat successes never notify.
* Delivery is not push: an online device syncs over Realtime, otherwise at the next 60-second heartbeat or WorkManager recovery run. Nothing is queued forever: Reset Timer 24 h, Force Reset and Debug Mode OFF 10 min, Debug Mode ON 24 h.

### Troubleshooting and rollback

* "Device is not enrolled" — claim a fresh token after enabling Remote Management.
* Access-denied or RLS errors — confirm the owner is a normal (non-anonymous) account and the device still belongs to it.
* Reset enrollment clears the device session and encrypted journal, rotates the installation ID, and disables Remote Management. Local settings, timers, Device Admin, and P2P are untouched.

## Broadcast

* action: `me.lucky.wasted.action.TRIGGER`
* receiver: `me.lucky.wasted/.TriggerReceiver`
* also you have to send a secret code from Wasted with the key: `code`

## Permissions

* DEVICE_ADMIN - lock and optionally wipe a device
* FOREGROUND_SERVICE - receive lock and USB state events
* RECEIVE_BOOT_COMPLETED - persist lock job and foreground service across reboots

## Localization

[<img 
     height="51" 
     src="https://badges.crowdin.net/badge/dark/crowdin-on-light@2x.png" 
     alt="Crowdin">](https://crwd.in/me-lucky-wasted)

## License

[![GNU GPLv3 Image](https://www.gnu.org/graphics/gplv3-127x51.png)](https://www.gnu.org/licenses/gpl-3.0.en.html)
