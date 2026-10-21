# Troubleshooting

| Symptom | Likely cause | Fix |
| --- | --- | --- |
| `Anonymous sign-ins are disabled` / enrollment fails | Auth provider not enabled | Authentication → Providers → enable **Allow anonymous sign-ins** |
| Create Account returns no session / “check your email” | Confirm Email is enabled | Authentication → Providers → disable **Confirm email** |
| `Invalid API key` / 401 | Wrong key or URL | Re-copy Project URL + publishable key; never use the secret key |
| `permission denied` (42501) | Direct table access / wrong role | Use the app/dashboard RPCs only; do not grant table writes |
| Empty dashboard data | Wrong account, RLS, or not enrolled | Confirm the same project and owner account; check enrollment |
| `setup SQL not applied` / missing relation | `setup.sql` not run or run partially | Run `setup.sql` once on a **fresh** project, then `verify.sql` |
| `pg_cron` extension error during setup | Extension unavailable | Database → Extensions → enable `pg_cron`, re-run setup on a fresh project |
| `update failed: relation exists` | Ran `setup.sql` on an existing project | Do not re-run setup; apply the release update bundle instead |
| Update bundle applied twice | Duplicate DDL | Restore backup and apply once; never re-run updates |
| Schema mismatch after update | Wrong/out-of-order bundle | Follow release notes stepwise (previous → next), then `verify.sql` |
| Device card shows “offline / stale” | No contact in 150 s | Bring the device online/unlocked; check heartbeat/network |
| Device never appears | Not enrolled or wrong project | Create a fresh token, claim it, check the same URL/key in app |
| Force Reset blocked | Debug Mode ON | Expected behavior; the owner can turn Debug Mode OFF remotely from the dashboard (with confirmation) or locally on the device |
| Command shows `device_revoked_during_execution` | Device was revoked while executing | Outcome is unknown by design; check the device locally. Do not retry destructively |
| Signed in but “Finish account setup” appears | Auth user exists without an owner profile | Enter a handle in the panel and submit; it retries `initialize_owner_account` |
| Framing/clickjacking concern | Host does not send framing headers | Deploy `web/_headers` or configure `frame-ancestors 'none'`/`X-Frame-Options` at the host |
| Force Reset rejected | Reset unsupported / not Device Admin | Check Device Admin/owner status on the device |
| Custom domain shows no data | CSP allows only `*.supabase.co` | Rebuild with adjusted CSP or use the Supabase host |
| Rate-limit errors | Auth abuse limits | Wait; review Authentication → Rate Limits |
| Dashboard lost connection | Network/Realtime drop | It refetches on reconnect; refresh the page if needed |

More: [setup.md](./setup.md) · [updates.md](./updates.md) · [security.md](./security.md)
