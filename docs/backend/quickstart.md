# Quick start (self-hosted)

Six steps, no CLI or Docker. Details are linked at the bottom.

1. **Create a free Supabase project** at <https://supabase.com/dashboard>.
2. **Open the app**: Remote Management → **Open setup wizard** → paste the **Project URL** and
   **Publishable key** (never the secret/service-role key).
3. **Set up the database**: in Supabase, open **SQL Editor**, run the release's `setup.sql` once,
   then **Authentication → Providers**: enable **Allow anonymous sign-ins**, disable **Confirm
   email**. Anonymous sign-ins give each device its own private identity, so your email/password is
   never stored on the device. If you do not want Remote Management, you can leave them off; the app
   and dashboard still work, but devices cannot enroll or sync. Under **Rate Limits**, set anonymous
   10/hour/IP and sign-in/sign-up 10 per 5 minutes/IP (or verify your values). Run `verify.sql`; every
   row must say PASS. The app never runs SQL; use **Save setup SQL file** in the wizard to move it to
   a computer if that is easier.
4. **Generate the dashboard** in the wizard and save it as `index.html`. Host it on
   <https://app.netlify.com/drop>: the temporary site is password-protected and expires after 1 hour
   until you click **Claim this site** and sign in/up. Copy the final URL. For strict framing
   protection, deploy a folder with `index.html` + `web/_headers` or set `frame-ancestors 'none'` at
   the host.
5. **Create your account** on the hosted dashboard URL.
6. **Connect the app**: paste the dashboard URL into Remote Management, Save, Enable; create an
   enrollment token in the dashboard and claim it in the app. Send Reset Timer to verify.

If you are upgrading, save the bundle whose name matches your installed version
(`update-from-<your version>-to-<current>.sql`); bundles are cumulative, so one file covers the
jump. Never re-run `setup.sql` on an existing project. If you are older than the oldest bundle,
step through releases or start fresh.

## First device vs additional device vs update

| Situation | Do this |
| --- | --- |
| New deployment (first device) | Create the project, run `setup.sql`, set Auth toggles, generate/host the dashboard, create the owner account, claim a token. |
| Additional device on an existing deployment | **Do not** run SQL, change Auth settings, or generate another dashboard. In Remote Management enter the same Project URL, publishable key, and dashboard URL; Enable; create a new token in the dashboard; claim it. |
| Existing installation after an app update | Install the new APK and run only the update bundle matching your installed version; never run `setup.sql`. |

Create one token per device; tokens are independent and each expires in 10 minutes.

**How the token works:** the dashboard asks Supabase for a one-time code (stored hashed), shows it to
you, and you paste it into the app on that device. The app sends it to Supabase, which binds that
device's own anonymous identity to your account and consumes the code. Every device gets its own
code; nothing is stored in the HTML file.

Too technical? A client-operated single backend (one Supabase project + one dashboard) removes all
per-user setup, but that is a product decision outside this self-hosted flow.

Details:
[setup.md](./setup.md) · [hosting.md](./hosting.md) · [updates.md](./updates.md) ·
[troubleshooting.md](./troubleshooting.md) · [security.md](./security.md)
