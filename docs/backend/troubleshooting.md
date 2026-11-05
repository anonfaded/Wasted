# Troubleshooting

| Symptom | Likely cause | Fix |
| --- | --- | --- |
| `Anonymous sign-ins are disabled` / enrollment fails | Auth provider not enabled | Remote Management needs this to give each device its own private identity without storing your password on it. Authentication → Providers → enable **Allow anonymous sign-ins**. If you leave it off, your owner account and dashboard still work, but devices cannot enroll or sync. |
| Create Account says the dashboard already has an owner | The Before User Created hook rejected a second email/password account | Sign in with the owner account. The hook intentionally allows only one non-anonymous account. |
| Create Account fails with “Account creation did not complete” | Confirm email is still ON, the Email provider is OFF, or the Before User Created hook is not enabled | Keep the **Email provider ON**, turn **Confirm email OFF**, and enable Before User Created with Hook type Postgres, schema public, function `hook_single_owner_signup`, then Save. |
| Second email account cannot sign up | Expected single-owner behavior | Use the owner account. Anonymous device identities remain allowed for device enrollment. |
| `Invalid API key` / 401 | Wrong key or URL | Re-copy Project URL + publishable key; never use the secret key |
| `permission denied` (42501) | Direct table access / wrong role | Use the app/dashboard RPCs only; do not grant table writes |
| Empty dashboard data | Wrong account, RLS, or not enrolled | Confirm the same project and owner account; check enrollment |
| `setup SQL not applied` / missing relation | `setup.sql` not run or run partially | Run `setup.sql` once on a **fresh** project, then `verify.sql` |
| `pg_cron` extension error during setup | Extension unavailable | Database → Extensions → enable `pg_cron`, re-run setup on a fresh project |
| `update failed: relation exists` | Ran `setup.sql` on an existing project | Do not re-run setup; apply the release update bundle instead |
| Update bundle applied twice | Duplicate DDL | Restore backup and apply once; never re-run updates |
| Schema mismatch after update | Wrong/out-of-order bundle | Apply the cumulative bundle matching the installed version, then `verify.sql` |
| Device card shows “offline / stale” | No contact in 150 s | Bring the device online/unlocked; check heartbeat/network |
| Device never appears | Not enrolled or wrong project | Create a fresh token, claim it, check the same URL/key in app |
| Force Reset blocked | Debug Mode ON | Expected behavior; the owner can turn Debug Mode OFF remotely from the dashboard (with confirmation) or locally on the device |
| Command shows `device_revoked_during_execution` | Device was revoked while executing | Outcome is unknown by design; check the device locally. Do not retry destructively |
| Signed in with a second email account | Only the first account can become owner | The dashboard signs that account out with “This dashboard already has an owner.” Use the first owner account; a second Auth user cannot see account data. |
| Framing/clickjacking concern | Host does not send framing headers | Deploy `web/_headers` or configure `frame-ancestors 'none'`/`X-Frame-Options` at the host |
| Force Reset rejected | Reset unsupported / not Device Admin | Check Device Admin/owner status on the device |
| Custom domain shows no data | CSP allows only `*.supabase.co` | Rebuild with adjusted CSP or use the Supabase host |
| Rate-limit errors | Auth abuse limits | Wait; review Authentication → Rate Limits |
| Dashboard lost connection | Network/Realtime drop | It refetches on reconnect; refresh the page if needed |

More: [setup.md](./setup.md) · [updates.md](./updates.md) · [security.md](./security.md)
