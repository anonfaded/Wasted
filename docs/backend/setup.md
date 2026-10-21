# Fresh Supabase setup

Use this for a new installation. For upgrades, see [updates.md](./updates.md).

## Prerequisites

- The Wasted app (v3.0.0+) installed.
- A free Supabase account.
- A place to host one HTML file over HTTPS (Netlify Drop is the simplest).

## 1. Create the project

1. Create a project at <https://supabase.com/dashboard>.
2. Open **Connect** (or **Settings → API Keys**) and copy:
   - **Project URL** — `https://<project-ref>.supabase.co`
   - **Publishable key** — `sb_publishable_...`

Never use a **secret/service-role** key in the app or dashboard. The publishable key is public by
design.

## 2. Set up the database

1. Open the project's **SQL Editor**.
2. Open [`supabase/releases/<current>/setup.sql`](../../supabase/releases/) (the app wizard copies
   the same file) and press **Run** once.
3. In **Authentication → Providers**:
   - enable **Allow anonymous sign-ins** (required for per-device identities);
   - disable **Confirm email** (the dashboard expects an immediate session after Create Account);
   - keep the default rate limits (CAPTCHA is optional and not required).
4. Run [`verify.sql`](../../supabase/releases/) in SQL Editor; every row must say **PASS**.

Do not run `setup.sql` twice and do not mix it with `supabase db push` on the same project.

## 3. Generate and host the dashboard

1. In the app: **Remote Management → Open setup wizard**.
2. Paste the Project URL and publishable key → **Save project details**.
3. **Generate dashboard file** → save `wasted-dashboard.html` anywhere via the Android file picker.
4. Host it: drag the file onto <https://app.netlify.com/drop>, claim the site to keep it online, and
   copy the `https://…netlify.app` URL. Alternatives: Cloudflare Pages, GitHub Pages, Vercel, any
   HTTPS static host.

The file contains only the project URL + publishable key. It is not a secret, but anyone who can
open the URL can attempt to create an account; RLS protects the data.

## 4. Create the owner and enroll the device

1. Open the hosted dashboard → **Create Account** (email, password ≥ 12 characters, handle).
2. In the dashboard, **Enroll a device → Create enrollment token** (valid 10 minutes).
3. In the app: paste the **Dashboard website URL**, Save.
4. Enable **Remote Management** (forces Debug Mode ON) → paste the token → **Claim**.
5. Wait for the device card to appear, then send **Reset Timer** and confirm the timer updates.

## 5. Post-setup checks

- Dashboard shows the device with “recently connected” (contact within 150 s).
- Debug Mode shows ON.
- Settings changes apply on the device at the next sync.
- Force Reset is blocked with Debug Mode ON.

More: [hosting.md](./hosting.md) · [security.md](./security.md) ·
[troubleshooting.md](./troubleshooting.md)
