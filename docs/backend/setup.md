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
2. Open the release's [`setup.sql`](../../supabase/releases/) (the app wizard can copy it or save it
   as a file; it never runs SQL itself) and run it once in **SQL Editor**. Running it from a computer
   is easier than a mobile browser.
3. In **Authentication → Providers**:
   - enable **Allow anonymous sign-ins** (required for per-device identities);
   - disable **Confirm email** (the dashboard expects an immediate session after Create Account);
   - in **Authentication → Rate Limits**, set anonymous sign-ins to 10/hour/IP and sign-in/sign-up
     to 10 per 5 minutes/IP (or verify your chosen values). CAPTCHA is optional.
4. Run the release's [`verify.sql`](../../supabase/releases/) in SQL Editor; every row must say
   **PASS**. The verifier checks FORCE RLS, exact policies/grants, RPC properties, Realtime scope,
   the cleanup job, and the schema marker — not just table names.

Do not run `setup.sql` twice and do not mix it with `supabase db push` on the same project.

## 3. Generate and host the dashboard

1. In the app: **Remote Management → Open setup wizard**.
2. Paste the Project URL and publishable key → **Continue**.
3. **Generate dashboard file** → save it as `index.html` via the Android file picker (the app
   suggests this name; Netlify Drop needs an `index.html` home page).
4. Host it: drag the file onto <https://app.netlify.com/drop>. The temporary site is
   password-protected and expires after 1 hour until you click **Claim this site** and sign in or
   sign up. Then copy the final `https://…netlify.app` URL. Alternatives: Cloudflare Pages, GitHub
   Pages, Vercel, any HTTPS static host.

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

## Multiple devices

Backend setup is **once per Supabase project/account**, not per device.

- **First device:** complete this whole page.
- **Additional devices:** do not run `setup.sql`, do not change Auth settings, and do not generate
  another dashboard. In the app, enter the same Project URL, publishable key, and dashboard URL,
  enable Remote Management, then create a new enrollment token in the dashboard and claim it.
- Create one token per device; tokens are independent and each expires in 10 minutes.
- Settings are account-wide; Debug Mode and commands are per device. Commands fan out to all active
  devices.

## How enrollment tokens work

The dashboard never adds a device by itself. The token is a one-time pairing code:

1. Signed in on the dashboard, click **Create enrollment token**. The browser calls
   `create_device_enrollment`; Supabase generates a random token, stores only its hash, and returns
   the plaintext once. It expires after 10 minutes.
2. Copy that token into the **Wasted app on the device** (Remote Management → token → Claim).
3. The app calls `claim_device_enrollment` with the token. Supabase hashes it, verifies it is unused
   and unexpired, binds that device's anonymous identity/installation to your account, and consumes
   the token.
4. Repeat for each device. Tokens are independent now, so you can create several. The first device
   gets no special token; every device uses one of these one-time codes.

The token is not embedded in the HTML file. It is a runtime value created and stored by Supabase;
the HTML is only the UI. The app never sees your owner password, and the dashboard never needs a
secret/service-role key.

More: [hosting.md](./hosting.md) · [security.md](./security.md) ·
[troubleshooting.md](./troubleshooting.md)
