# Changelog

## Wasted v3.0.0 - October 22, 2026

### New Features
- Self-hosted Remote Management with your own Supabase project and dashboard.
- Biometric app unlock setting, so the launch prompt can be turned off.
- Account name saved to Supabase and editable from the dashboard.
- Dashboard installs as an app with its own icon and works offline on supported browsers.
- Signup is direct and owner-only; no confirmation email is needed, and later accounts are blocked for security.
- Remote data stays within the Supabase free plan: command history is cleaned after 180 days, enrollment tokens after 30 days, and the dashboard only polls visible tabs.

### Enhancements
- P2P security now uses certificate pinning and an encrypted peer database (re-pair existing peers once).
- Home screen Help explains the secret code, wipe options, protection level, and setup.