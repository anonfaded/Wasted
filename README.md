# Wasted (Modded v3.0.0)

**This is a modded version of [Wasted](https://github.com/x13a/Wasted)** — the original open-source emergency lock & factory reset app by [@x13a](https://github.com/x13a).

## What's New in This Fork

- **P2P Network**: Remote factory reset via encrypted local Wi-Fi (TLS encrypted messaging on port 9876)
- **Android 14+ Device Owner Setup**: Interactive Shizuku-based setup to make Wasted Device Owner for full factory reset capability
- **Fixed Android 14+ Reset**: Reset now uses proper `wipeDevice()` API instead of deprecated `wipeData()`
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

This fork adds optional remote management through your own Supabase project. It is disabled by default and performs no network work until it is configured, enrolled, and enabled.

### Backend setup

1. Create a Supabase project and apply the migrations in `supabase/migrations/` in order (the linked project was built through the Supabase MCP `apply_migration` tool).
2. Keep email/password sign-in for owner accounts and enable anonymous sign-ins for per-device identities. The repository's `supabase/config.toml` mirrors the required Auth settings and rate limits.
3. The app and dashboard store only the project URL and a publishable (anon) key. Never use a secret or service-role key.

### Android setup

1. Open **Remote Management** and enter the project URL, publishable key, and dashboard URL; save the configuration.
2. In the dashboard, create an enrollment token (valid 10 minutes).
3. Enable Remote Management (this forces Debug Mode ON), enter the token, and claim it. The device appears in the dashboard after the first sync.

### Dashboard

* `cd web && npm install && npm test && npm run build` produces a single `dist/index.html`.
* Edit the CONFIG block at the top of that file (project URL, publishable key, product/version/footer links) and copy it to any HTTPS static host. There is no CDN, server runtime, or build step at the host. `config.example.js` documents the fields for source builds.
* The page ships a restrictive CSP meta policy (`default-src 'none'`, Supabase-only connections, inline scripts/styles) and `no-referrer`. For strict deployments, serve `config.js` externally and set CSP hashes plus `frame-ancestors 'none'` via response headers, since meta policies cannot set framing rules.
* Sign In and Create Account are explicit; a failed sign-in never creates an account.

### Behavior and limits

* Device cards show reported state; Realtime only triggers a refetch and never executes payloads directly. A device counts as "recently connected" for 150 seconds; timers are extrapolated locally.
* Lock Timer / USB Trigger changes are revision-protected and apply to every enrolled device.
* Reset Timer restarts the lock timer. Force Reset sends a factory reset (typed confirmation in the dashboard) and only executes while Debug Mode is OFF.
* Debug Mode is ON by default and blocks destructive remote commands. The dashboard asks for confirmation in both directions; the device applies remote toggles without a local dialog. Turning it OFF expires after 10 minutes if the device stays offline, and supersedes any pending Force Reset.
* Optional notifications (off by default, `remote_events` channel) cover settings applied, Reset Timer, Force Reset, blocked or failed commands, manual-sync success, and sync failures. Repeated notices replace each other instead of stacking, and heartbeat successes never notify.
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
