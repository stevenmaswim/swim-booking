# KSJ Swimming — Booking Website

A booking site with no payment infrastructure. Customers with the link book a lesson with just name + email + phone. Staff log in to publish slots per pool, manage clients, and see bookings; admins additionally see revenue.

**Cost to run: $0** (Supabase free tier + Netlify free tier).

## What's included

| File | Purpose |
|---|---|
| `index.html` | Public home page (About the Coaches + pools load automatically) |
| `book.html` | Customer booking page — share this link in your WeChat group |
| `mybookings.html` | Customer self-service: view/cancel your bookings via an emailed code |
| `staff.html` | Staff dashboard (Google or email login, staff-only) |
| `supabase/schema.sql` | Database, security rules, and booking logic |
| `supabase/migration_google_auth.sql` | Google sign-in + staff allowlist (run after `schema.sql`) |
| `supabase/migration_clients_revenue.sql` | Client CRM + admin-only revenue tracking |
| `supabase/migration_v3.sql` | Photos, public booked-slot visibility, coach/admin permissions |
| `supabase/migration_v4.sql` | First/last/parent names, self-service bookings, emails, per-year revenue |
| `supabase/migration_security.sql` | Security hardening (run after v4) |
| `supabase/migration_v5.sql` | Slot editing + history/export support |
| `supabase/migration_v6.sql` | Late-cancel monitor, admin Team management, admin slot reopen, hour×day revenue grid, multi-slot booking with email verification |
| `supabase/migration_v7.sql` | Revenue grid cells gain a per-coach breakdown |
| `supabase/migration_v8.sql` | Per-student overlap rule: one email can book different kids into simultaneous lessons (run last) |
| `supabase/verify_v6.sql` | Post-migration test suite for the SQL Editor — reports PASS/FAIL in a deliberate final "error", rolls everything back |
| `supabase/verify_v6_api.mjs` | Permission checks against the live REST API with real staff JWTs |
| `supabase/functions/emails/` | Edge Function that sends confirmation, reminder, and login-code emails via Resend |
| `config.js` | Your Supabase keys go here |
| `styles.css` | Shared styling |

## Setup (~15 minutes)

### 1. Create the backend (Supabase)
1. Go to [supabase.com](https://supabase.com) → sign up → **New project** (free tier). Pick a strong database password and a region near you.
2. In the dashboard, open **SQL Editor** → **New query** → paste the entire contents of `supabase/schema.sql` → **Run**.
3. Same again for `supabase/migration_google_auth.sql` → **Run**. This adds Google sign-in support and the staff allowlist.
4. Same again for `supabase/migration_clients_revenue.sql` → **Run**. This adds client tracking (CRM) and revenue reporting.
5. Same again for `supabase/migration_v3.sql` → **Run**. This adds photos, publicly visible booked slots, and coach/admin permissions. **Watch the output for a NOTICE about storage** — if it appears, your project doesn't allow storage setup via SQL; create the bucket by hand: **Storage → New bucket** → name `photos` → check **Public bucket** → Save, then under the bucket's **Policies** add: SELECT for everyone, INSERT and UPDATE for `authenticated`.
6. Same again for `supabase/migration_v4.sql` → **Run**. This adds first/last/parent names, the self-service **My Bookings** flow, email support, and per-year revenue. **Watch for a NOTICE about the reminder cron** — it's expected until you finish the email setup (next section); the rest of the migration still applies. The confirmation/reminder/code **emails only work once you set up the Edge Function** below.
7. Same again for `supabase/migration_security.sql` → **Run** (security hardening), then `supabase/migration_v5.sql` → **Run** (slot editing).
8. Same again for `supabase/migration_v6.sql` → **Run**. This adds the late-cancellation monitor, the admin **Team** tab, admin slot reopen, the hour×day revenue grid, and **multi-slot booking with email verification**. ⚠️ v6 **replaces the booking RPC** (`book_slot` → `book_slots` with a verification code): run it and push the updated `book.html` **at the same time**, and redeploy the `emails` Edge Function — an old page against a new database (or vice-versa) can't take bookings.
9. Same again for `supabase/migration_v7.sql` → **Run**. Each revenue-grid cell now includes a per-coach breakdown (shown as a hover/tap tooltip in the Revenue tab). Frontend-only additions ride along in `staff.html`: per-coach booked/open hours under the calendar legend, and cancellation timestamps on cancelled bookings.
10. Same again for `supabase/migration_v8.sql` → **Run**. Bookings carry a **student per lesson**: one parent email can book two different kids into simultaneous lessons; only the *same* student is blocked from overlapping times (in the checkout and against existing bookings, and when staff move a booked slot). ⚠️ The `book_slots` call shape changed — run this **together with** pushing the updated `book.html` and redeploying the `emails` Edge Function.
11. **Verify it worked:** paste `supabase/verify_v6.sql` into the SQL Editor → **Run**. The run **ends in an ERROR on purpose** — the error message *is* the report (the editor hides notices, and erroring out forces Postgres to roll back all the test data). Read the PASS/FAIL lines in it; the first line is the summary. For an end-to-end check with real logins, see `supabase/verify_v6_api.mjs` (header comment explains usage).
6. **Allowlist your staff.** Anyone with a Google account can *sign in*, but only emails in the `staff_emails` table can use the dashboard (enforced in the database, not just the UI). In the SQL Editor:
   ```sql
   insert into public.staff_emails (email) values
     ('coach1@gmail.com'),
     ('coach2@gmail.com');
   ```
   Add each allowlisted email **before** the person's first sign-in if you can — their coach profile is then created automatically. (If they signed in first, no problem: the profile is created the next time they open the dashboard.)
7. **Promote yourself (or another user) to admin** to unlock the Revenue tab. Admins see revenue, set the default lesson price, can cancel any slot/booking, and are the only ones who can edit or delete clients; coaches manage only their own slots (the database refuses, not just the UI). Find the user's id under **Authentication → Users**, then in the SQL Editor:
   ```sql
   update public.profiles set role = 'admin' where id = '<user-uuid>';
   ```
   (The `role` column can only be changed here — it is not writable through the API.)
8. Keep **Authentication → Sign In / Up → "Allow new users to sign up" ENABLED.** Google sign-in needs it to create accounts on first login; the allowlist is what protects the dashboard and the data. (If you disabled this earlier, re-enable it.)
9. (Optional) For staff who won't use Google: **Authentication → Users → Add user → Create new user** (email + password) — and add that same email to `staff_emails` too.
10. Go to **Project Settings → API** (or “Data API”) and copy the **Project URL** and **anon public key**.

### 2. Enable Google sign-in

**a) Create a Google OAuth client** (once, ~5 min):
1. Go to [console.cloud.google.com](https://console.cloud.google.com) → create/select a project → **APIs & Services → Credentials → Create credentials → OAuth client ID** (configure the consent screen first if prompted — "External", app name, your email; no scopes beyond the defaults needed).
2. Application type: **Web application**.
3. Under **Authorized redirect URIs** add your Supabase callback (replace `xxxx` with your project ref, visible in your Project URL):
   ```
   https://xxxx.supabase.co/auth/v1/callback
   ```
4. Copy the **Client ID** and **Client Secret**.

**b) Turn on the provider in Supabase:**
1. **Authentication → Providers** (aka Sign In / Up → Auth Providers) **→ Google** → enable, paste the Client ID and Client Secret → **Save**.

**c) Whitelist your site's redirect URLs** — after Google login, Supabase only redirects back to URLs on this list. **Authentication → URL Configuration**:
1. **Site URL:** your production URL, e.g. `https://stevenmaswim.github.io/swim-booking/`
2. **Additional Redirect URLs** — add all three (VS Code Live Server answers on both hostnames):
   ```
   http://localhost:5500/staff.html
   http://127.0.0.1:5500/staff.html
   https://stevenmaswim.github.io/swim-booking/staff.html
   ```
   If you deploy somewhere else (e.g. Netlify), add `https://your-site.netlify.app/staff.html` instead of the GitHub Pages URL.

### 3. Configure the site
Open `config.js` and paste your two values:
```js
const SUPABASE_URL = "https://xxxx.supabase.co";
const SUPABASE_ANON_KEY = "eyJ...";
const BUSINESS_TIMEZONE = "America/Chicago";   // the pool's local timezone (IANA name)
```
(The anon key is safe to publish — all protection comes from database Row Level Security.)

**`BUSINESS_TIMEZONE`** is the single source of truth for the pool's local time. Lesson times are stored in UTC and shown in this zone on the *record* surfaces — the confirmation/reminder/change emails, the CSV export, and the **My Bookings** list — so they always match the clock at the pool regardless of the viewer's device or the server region. Use an [IANA name](https://en.wikipedia.org/wiki/List_of_tz_database_time_zones) (e.g. `America/Chicago`, `America/Winnipeg`, `America/New_York`); DST (CDT/CST etc.) is handled automatically. If you change it, also update the matching `BUSINESS_TIMEZONE` secret on the emails Edge Function (below). Note: the *browsing* calendars in `book.html` and `staff.html` intentionally show times in the visitor's own device timezone; only the record surfaces are pinned to the pool zone.

If the values are missing or wrong, every page shows a red banner explaining what to fix — a misconfigured site never renders as a silent blank page.

### 3b. Emails (Resend + Edge Function)

Booking confirmations, 2-day reminders, and the **My Bookings** login codes are sent by the `emails` Edge Function using [Resend](https://resend.com) (free tier: 100 emails/day, 3,000/month). Booking still works without this — customers just won't get emails and My Bookings can't send codes.

**a) Resend account + sender**
1. Sign up at [resend.com](https://resend.com) → **API Keys → Create API Key** → copy it.
2. Verify a sender so email isn't rejected:
   - **Best:** **Domains → Add Domain**, add the DNS records they show, and use a from-address like `no-reply@yourdomain.com`.
   - **Quick test:** you can send from `onboarding@resend.dev` (Resend's shared sender) to *your own* address only — fine for testing, not for customers.

**b) Install the Supabase CLI and log in**
```bash
brew install supabase/tap/supabase   # macOS; see supabase.com/docs/guides/cli for other OSes
supabase login                        # opens a browser to authorize
```
(Global `npm i -g supabase` is no longer supported by Supabase — use Homebrew or the platform installer. The commands below pass `--project-ref` so you don't need `supabase link`.)

**c) Set the function secrets** (these are NOT in git). Generate a `CRON_SECRET` first and keep a copy — you'll reuse it in step (e):
```bash
supabase secrets set --project-ref jvzahjtoiwfsshgzsyym \
  RESEND_API_KEY="re_xxx" \
  FROM_EMAIL="KSJ Swimming <no-reply@ksjswimming.com>" \
  SITE_URL="https://stevenmaswim.github.io/swim-booking" \
  BUSINESS_TIMEZONE="America/Chicago" \
  CRON_SECRET="$(openssl rand -hex 16)"
```
(`SUPABASE_URL` and `SUPABASE_SERVICE_ROLE_KEY` are provided automatically.) `BUSINESS_TIMEZONE` is the pool's local timezone used to format every time in the emails — keep it equal to the `BUSINESS_TIMEZONE` in `config.js`. It's optional; if unset the function defaults to `America/Chicago`. You can verify the from-domain (`ksjswimming.com` here) under Resend → **Domains**; until a domain is verified you can only send from `onboarding@resend.dev` to your own address.

**d) Deploy the function** — booking and the code request are anonymous, so JWT verification must be off:
```bash
supabase functions deploy emails --project-ref jvzahjtoiwfsshgzsyym --no-verify-jwt
```

**e) Turn on reminder emails.** Schedule the hourly job in the **SQL Editor** (not the migration file — this carries the real secret and must stay out of git). Paste, replacing `<CRON_SECRET>` with the value from step (c):
```sql
create extension if not exists pg_net with schema extensions;
create extension if not exists pg_cron;
select cron.unschedule('ksj-lesson-reminders')
where exists (select 1 from cron.job where jobname = 'ksj-lesson-reminders');
select cron.schedule('ksj-lesson-reminders', '0 * * * *', $$
  select net.http_post(
    url := 'https://jvzahjtoiwfsshgzsyym.supabase.co/functions/v1/emails',
    headers := jsonb_build_object('Content-Type','application/json','x-cron-secret','<CRON_SECRET>'),
    body := jsonb_build_object('type','reminders'));
$$);
```
(`migration_v4.sql` also attempts this with a `__CRON_SECRET__` placeholder, but the SQL-Editor snippet above is the authoritative way — it keeps the real secret out of the repo.) Test immediately without waiting for the hour:
```bash
curl -X POST https://jvzahjtoiwfsshgzsyym.supabase.co/functions/v1/emails \
  -H "Content-Type: application/json" -H "x-cron-secret: <your CRON_SECRET>" \
  -d '{"type":"reminders"}'
```
It returns `{"sent": N}` and stamps `reminded_at` so nobody is emailed twice.

All emails are signed **KSJ Swimming** with reply-to **ksjswimming@gmail.com**.

### 4. Deploy

**GitHub Pages** (this repo): push to `main`, then repo **Settings → Pages → Deploy from a branch → main / (root)**. The site appears at `https://stevenmaswim.github.io/swim-booking/`.

**Or Netlify:** go to [app.netlify.com/drop](https://app.netlify.com/drop) and drag the whole `swim-booking` folder in — you get `https://your-site.netlify.app`.

Either way, share `<your-site>/book.html` in your WeChat group, and make sure `<your-site>/staff.html` is in the Supabase redirect-URL list (step 2c).

### 5. First run
1. Open `/staff.html`, sign in with Google (or email), add your **pools** first.
2. Each coach uploads a **photo** on My Profile, and add photos to pools on the Pools tab — they show on the public pages.
3. Use **Publish Slots** to post bookable times (date, start time, length, how many back-to-back slots, pool, coach, price — prefilled with the default an admin sets on the Revenue tab).
4. Customers book on `/book.html` — a weekly calendar they can filter by pool, coach, day, and time of day. Booked slots stay visible (greyed, showing "FirstName L." + coach). Every booking creates/updates a client record in the **Clients** tab and sends a confirmation email; a reminder goes out ~2 days before. Customers manage their own lessons at `/mybookings.html` with an emailed code.

## Pre-launch checklist

Before sharing the booking link with real families. (Full audit: `PRELAUNCH_AUDIT.md`.)

**Deploy in this exact order** — the pieces depend on each other:
1. **Migrations** — in the SQL Editor, run in order: `schema.sql` →
   `migration_google_auth.sql` → `migration_clients_revenue.sql` → `migration_v3.sql`
   → `migration_v4.sql` → `migration_security.sql` → `migration_v5.sql` →
   `migration_v6.sql` → `migration_v7.sql` → `migration_v8.sql`. (Idempotent from v5 on — safe to re-run.)
2. **Edge Function secrets** — `supabase secrets set … RESEND_API_KEY / FROM_EMAIL /
   SITE_URL / BUSINESS_TIMEZONE / CRON_SECRET` (§3b).
3. **Deploy the Edge Function** — `supabase functions deploy emails --no-verify-jwt`
   (JWT off is required: booking + code requests are anonymous).
4. **Enable the reminder cron** — run the `cron.schedule` block from §3b(e) with your
   real `CRON_SECRET` (not the `__CRON_SECRET__` placeholder).
5. **Deploy the site** (§4) and confirm `<site>/staff.html` is in Supabase → Auth →
   URL Configuration → Redirect URLs.
6. **Verify** — run `supabase/verify_v6.sql` in the SQL Editor; the report (delivered as
   a deliberate final ERROR) must say **ALL GREEN**. Then do one real end-to-end booking
   with your own email: select 2 slots → get the code → confirm → check the single
   confirmation email lists both lessons in Central time → cancel via its link.

**Supabase console settings to confirm (not covered by migrations):**
- **Auth → email/password self-signup**: the `staff_emails` allowlist + RLS is the real
  gate — no one reaches the dashboard or any PII without being allowlisted, signups on or
  off. To stop *strangers self-registering* email/password accounts, disable the **Email
  provider's** signup (Authentication → Providers → Email) **only if all your staff use
  Google**; admins can still create email accounts via **Authentication → Users → Add
  user** (that bypasses the toggle). ⚠️ Do **not** use the global "disable signups" —
  it also blocks a newly-allowlisted coach's first Google sign-in. (Note: Google logins
  still create authenticated users, so this doesn't fully close audit L1 — which is Low
  and already neutralized by the allowlist.)
- **Auth → URL Configuration**: Site URL + redirect URLs include your real staff URL.
- **Storage → `photos`**: bucket is **Public**; INSERT/UPDATE policies limited to image
  files under `coaches/`/`pools/`; **set a file-size limit** and, ideally, bind writes to
  the owner (audit M2). Auto-created by `migration_v3.sql` unless you saw its NOTICE.
- **Resend → Domains**: `ksjswimming.com` (or your domain) **verified**, and
  `FROM_EMAIL` uses it — until verified you can only send to your own address.
- **Database → Extensions**: `pg_cron` + `pg_net` enabled (for reminders).

**Watch in the first week:**
- **Resend dashboard** — delivery/bounce/spam rate; you're on the free tier
  (100/day, 3,000/mo) — confirmation + reminder + code emails all draw from it.
- **Supabase → Auth logs / API logs** — unexpected 4xx/5xx spikes or unfamiliar signups.
- **`booking_otps` growth** — a sudden spike = someone hammering the code endpoint
  (rate-limited, but a signal to add CAPTCHA — audit M3). `purge_expired_otps()` keeps
  it tidy; schedule it hourly if you like.
- **A few real cancellations** — confirm the timestamps + late-cancel badges look right
  in the Clients/History tabs.

**Rollback:** the frontend is static — `git revert` the bad commit and push; GitHub
Pages redeploys in ~1 min. The DB migrations are additive; the only destructive step in
this batch was `migration_v6.sql` **dropping `book_slot`** (replaced by `book_slots`), so
a frontend rollback past v6 also needs that function restored. Safer path: roll the
frontend forward with a fix rather than back across the v6 boundary. Edge Function: keep
the previous version's code to redeploy if a send path breaks.

## How client data is protected

- **Bookings are invisible to the public.** Row Level Security blocks all anonymous reads of the bookings table — customer emails/phones are only visible to logged-in staff.
- **Booking happens only through a locked-down database function.** `book_slots()` validates the email/phone, **requires a 6-digit emailed verification code** (or a 24-hour token from a previous verification), limits each email to 8 upcoming bookings (anti-spam), books up to 8 lessons atomically (all-or-nothing), and uses row locks + a unique index so two people can never book the same slot, even clicking at the same instant.
- **Cancellations use a private token** shown once after booking — no one can cancel (or discover) someone else's booking.
- **Anyone can sign in with Google, but only allowlisted staff get access.** Every Row Level Security policy checks the signed-in email against the `staff_emails` table (via the `is_staff()` database function), so a random Google account can't read bookings or touch pools/slots even by calling the API directly. The dashboard also signs such accounts out with "This account is not authorized as staff."
- **Client records are staff-only.** The `clients` table has no anonymous access at all; rows are created only inside the `book_slots` function. Only admins can edit or delete clients — deleting anonymizes the client's past bookings instead of erasing history.
- **Booked slots are publicly visible, but only the slot.** The public calendar shows booked times greyed out (time/pool/coach only) so customers see the schedule shape — booking details, names, emails and phones stay staff-only.
- **Coaches manage only their own lessons.** Row Level Security lets a coach cancel only slots/bookings where they are the assigned coach; admins can cancel anything. Hiding the buttons is cosmetic — the database enforces it.
- **No double-booking the same student.** `book_slots` rejects a booking only if the **same student** (per lesson, case-insensitive) already has a confirmed lesson overlapping the requested time — including within the set being booked together. Different kids on one parent email may book simultaneous lessons freely.
- **Only a first name + last initial is public.** Booked slots show e.g. "Jane D." via a single `slots.booked_by_display` column — never the full last name, parent/guardian name, email, or phone. The parent/guardian name is staff-only and has no public read path.
- **Self-service bookings are gated by an emailed code.** `My Bookings` sends a 6-digit code (hashed, 10-min expiry, rate-limited, max 5 attempts); only after it matches does `verify_and_list_bookings()` return that email's own lessons. Anonymous users still cannot read the bookings or clients tables directly.
- **Revenue is admins-only, enforced in the database.** Slot prices have no API read permission for anyone (column-level grants), and revenue comes only from `get_revenue_report()`, which raises an error unless the caller's profile has `role = 'admin'`. Coaches can set a price when publishing slots but can't read prices back in bulk, and the `role` column itself can't be written through the API.
- Everything runs over HTTPS on Supabase/GitHub Pages/Netlify.

## Weekly routine

Every week: staff open **Publish Slots**, enter that week's times per pool, done. Customers rebook from the same link. You can also duplicate a whole week quickly by re-entering the same form with a new date.

## Staff dashboard cheat-sheet (v6)

- **Clients tab** shows a **Late cancels** count — cancellations made less than 24h before the lesson get an amber badge (red at 3+). Every cancelled booking in a client's history or the History tab shows **when** it was cancelled in the pool's timezone (late ones as "Cancelled <24h — 5h before (Jul 9, 10:12 PM)"; pre-v6 rows show "time unknown"), with a tooltip carrying the exact time and lead. Purely informational: nothing blocks a client from cancelling.
- **Team tab (admins)** edits any coach's name, bio, photo, visibility, and role. Promoting/demoting is instant; demoting the **last** admin is blocked by the database.
- **Export week (CSV)** on the calendar downloads the displayed week as an hours log (times in the pool's timezone) with per-coach booked/open hour totals — any staff member can use it.
- **Reopen (admins)**: cancelled *future* slots get a Reopen button in the History tab.
- **Revenue tab (admins)** starts with the hour-of-day × day-of-week grid (like the paper sheet) with row/column/grand totals and its own CSV export; hovering (or tapping) a cell shows each coach's share of it. The by-week/coach/pool summaries are below.
- **Calendar** shows each coach's booked/open hours for the displayed week under the pool legend (e.g. "Kevin Li: 6.5h booked · 2h open") — schedule data, visible to all staff.
- **Coaches** publish/edit/cancel only their own slots; admins do all of this for anyone, including creating slots assigned to any coach.

## Ideas for later

- **Email confirmations:** add a Supabase Edge Function + free [Resend](https://resend.com) account to auto-email the cancel link.
- **Coach photos:** add a `photo_url` column to `profiles` and an `<img>` in `index.html`.
- **Group lessons:** add a `capacity` column to slots and adjust `book_slots` to count bookings instead of flipping status.
- **Chinese translation:** duplicate `book.html` as `book-zh.html` for the WeChat group.

## Troubleshooting

- **Red banner on every page** → `config.js` still has placeholder values, or the URL/key are wrong. The banner text says which.
- **"Could not load slots"** → check `config.js` values, and that `schema.sql` ran without errors.
- **"This account is not authorized as staff"** → that email isn't in `staff_emails`. Add it in the SQL Editor (must match the Google account's email exactly, case doesn't matter).
- **"Could not verify staff access"** → `supabase/migration_google_auth.sql` hasn't been run on this project.
- **"Could not load settings" / empty Clients tab** → `supabase/migration_clients_revenue.sql` hasn't been run.
- **No Revenue tab after signing in** → your profile isn't an admin yet; run the `update public.profiles set role='admin'…` SQL from setup step 1.6 (or have an existing admin promote you in the **Team** tab).
- **Booking fails with "Could not find the function … book_slots"** → `supabase/migration_v6.sql` hasn't been run on this project.
- **Booking fails with "verify your email"** even after entering a code → the code expired (10 min) or 5 wrong attempts locked it; request a fresh one.
- **"function book_slot does not exist" from an old page** → the deployed `book.html` is older than the database; push the current frontend (v6 replaced `book_slot` with `book_slots`).
- **My Bookings never emails a code / booking sends no confirmation** → the `emails` Edge Function isn't set up. Do section **3b**. Test with the `curl` command there; a `RESEND_API_KEY not set` error means the secret is missing.
- **Reminders never arrive** → confirm `pg_cron`/`pg_net` are enabled (Database → Extensions) and that you replaced `__CRON_SECRET__` in `migration_v4.sql` with the real value and re-ran that block. `select * from cron.job;` should list `ksj-lesson-reminders`.
- **Google button bounces back to the login page** → the page's URL isn't in **Authentication → URL Configuration → Additional Redirect URLs** (see step 2c), or the provider isn't enabled.
- **Google says "redirect_uri_mismatch"** → the Supabase callback URL is missing from the Google Cloud OAuth client's Authorized redirect URIs (step 2a).
- **New Google user can't sign in at all ("Signups not allowed")** → re-enable **Allow new users to sign up** (step 1.5); the allowlist is what keeps strangers out of the dashboard.
- **Staff sign in with Google only.** The Email/password provider is disabled (Authentication → Providers → Email), so the login page shows just the Google button. If you ever need email/password logins back, re-enable the Email provider and add the account under Authentication → Users → Add user.
- **Coach missing from dropdowns** → profiles are created automatically only for allowlisted emails; opening the dashboard once creates a missing profile. If it's still missing, insert a row into `profiles` manually.
