# Remote backend — Supabase

Reproducible infrastructure for the optional Remote Management feature. Git is the source of truth for structure and configuration; it never contains project secrets or client data.

## Bootstrap

1. Create a Supabase project and link it locally (`supabase link --project-ref <project-ref>`); keep credentials in the gitignored `.env` (copy `.env.example`).
2. Apply migrations in order through Supabase MCP `apply_migration` (do not use the dashboard schema editor). The versions recorded in `supabase_migrations.schema_migrations` must match the filenames in `migrations/`.
3. Apply the non-SQL settings in the hosted-project manifest below through the Auth dashboard.
4. Run all four SQL suites in `tests/` inside rolled-back transactions (each file starts with `begin;` and ends with `rollback;`).
5. Generate website types (`supabase gen types typescript --linked` or MCP `generate_typescript_types`) and refresh `web/src/database.types.ts`.
6. Review security and performance advisors with MCP `get_advisors`.

## Hosted project manifest (non-secret)

Record and verify these values for every project:

| Setting | Expected |
| --- | --- |
| Auth providers | Email/password for owners; anonymous sign-ins for devices |
| Sign-up | No confirmation email required for the owner flow; no recovery-email UI shipped |
| Rate limits | Anonymous sign-ups 10/hour/IP; sign-in/sign-up 10 per 5 minutes/IP |
| Redirect URLs | None required (no email magic links) |
| Exposed schemas | `public` only; `private` schema usage/grants revoked |
| Extensions | `pgcrypto` (digest, random bytes); `pg_cron` (daily anonymous-identity cleanup) |
| Realtime | Publication `supabase_realtime` contains only `account_settings`, `devices`, `device_status`, `device_commands` |
| RLS | Enabled and forced on every remote table; writes only through SECURITY DEFINER RPCs |
| Advisors | `authenticated_security_definer_function_executable` (owner-only RPC surface by design), `rls_enabled_no_policy` on `private.device_enrollments` (deny-all by design), unused FK indexes on an empty schema |

## Verification commands

- Schema/RLS/RPC/concurrency: run each `tests/*.sql` against the linked database inside a transaction and `rollback`.
- Migration history: compare `supabase_migrations.schema_migrations` with the filenames in `migrations/`.
- Types: regenerate and confirm `web/src/database.types.ts` only changes with schema changes.
- Clean replay: `supabase db reset` (requires Docker) must succeed from migrations plus `seed.sql`; then `supabase db diff --linked` must be empty.
- Secret scan: `git grep -nE 'sb_secret_|service_role|postgres(ql)?://[^ ]+@|BEGIN [A-Z ]*PRIVATE KEY'` must return only validator/test constants.

## Recreate on another account

1. Create the target project and verify its identity through MCP.
2. Apply the tracked migrations in order.
3. Apply the Auth manifest above.
4. Run all four test suites, the advisors, and the clean replay/diff checks.
5. Deploy `web/dist/index.html` configured with the target URL and publishable key.
6. Create the first owner through the dashboard Create Account flow, then enroll a spare device with a fresh token.

## Rollback

- Disable Remote Management locally: stops Realtime, clears the active session, and leaves local/P2P behavior untouched.
- Replace the hosted dashboard artifact with the previous build; the RPC surface stays backward compatible.
- Downgrade the APK only to a version compatible with the additive schema.
- Corrections are forward-only compensating migrations. Never drop or rename columns or relax RLS; preserve command and audit evidence.

## Secrets and data

Never commit `.env`, database URLs or passwords, service-role or secret keys, JWT signing keys, signing material, enrollment tokens, real account/device data, or dumps. The publishable key is not a secret, but client-specific values are still kept out of tracked source.
