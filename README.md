# Swim Lessons Booking Website

A booking site with no payment infrastructure. Customers with the link book a lesson with just name + email + phone. Staff log in to set availability, publish slots per pool, and see bookings.

**Cost to run: $0** (Supabase free tier + Netlify free tier).

## What's included

| File | Purpose |
|---|---|
| `index.html` | Public home page (About the Coaches + pools load automatically) |
| `book.html` | Customer booking page — share this link in your WeChat group |
| `staff.html` | Staff dashboard (Google or email login, staff-only) |
| `supabase/schema.sql` | Database, security rules, and booking logic |
| `supabase/migration_google_auth.sql` | Google sign-in + staff allowlist (run after `schema.sql`) |
| `supabase/migration_clients_revenue.sql` | Client CRM + admin-only revenue tracking (run last) |
| `config.js` | Your Supabase keys go here |
| `styles.css` | Shared styling |

## Setup (~15 minutes)

### 1. Create the backend (Supabase)
1. Go to [supabase.com](https://supabase.com) → sign up → **New project** (free tier). Pick a strong database password and a region near you.
2. In the dashboard, open **SQL Editor** → **New query** → paste the entire contents of `supabase/schema.sql` → **Run**.
3. Same again for `supabase/migration_google_auth.sql` → **Run**. This adds Google sign-in support and the staff allowlist.
4. Same again for `supabase/migration_clients_revenue.sql` → **Run**. This adds client tracking (CRM) and revenue reporting.
5. **Allowlist your staff.** Anyone with a Google account can *sign in*, but only emails in the `staff_emails` table can use the dashboard (enforced in the database, not just the UI). In the SQL Editor:
   ```sql
   insert into public.staff_emails (email) values
     ('coach1@gmail.com'),
     ('coach2@gmail.com');
   ```
   Add each allowlisted email **before** the person's first sign-in if you can — their coach profile is then created automatically. (If they signed in first, no problem: the profile is created the next time they open the dashboard.)
6. **Promote yourself (or another user) to admin** to unlock the Revenue tab. Admins see revenue reports and set the default lesson price; coaches can't (the database refuses, not just the UI). Find the user's id under **Authentication → Users**, then in the SQL Editor:
   ```sql
   update public.profiles set role = 'admin' where id = '<user-uuid>';
   ```
   (The `role` column can only be changed here — it is not writable through the API.)
7. Keep **Authentication → Sign In / Up → "Allow new users to sign up" ENABLED.** Google sign-in needs it to create accounts on first login; the allowlist is what protects the dashboard and the data. (If you disabled this earlier, re-enable it.)
8. (Optional) For staff who won't use Google: **Authentication → Users → Add user → Create new user** (email + password) — and add that same email to `staff_emails` too.
9. Go to **Project Settings → API** (or “Data API”) and copy the **Project URL** and **anon public key**.

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
```
(The anon key is safe to publish — all protection comes from database Row Level Security.)

If the values are missing or wrong, every page shows a red banner explaining what to fix — a misconfigured site never renders as a silent blank page.

### 4. Deploy

**GitHub Pages** (this repo): push to `main`, then repo **Settings → Pages → Deploy from a branch → main / (root)**. The site appears at `https://stevenmaswim.github.io/swim-booking/`.

**Or Netlify:** go to [app.netlify.com/drop](https://app.netlify.com/drop) and drag the whole `swim-booking` folder in — you get `https://your-site.netlify.app`.

Either way, share `<your-site>/book.html` in your WeChat group, and make sure `<your-site>/staff.html` is in the Supabase redirect-URL list (step 2c).

### 5. First run
1. Open `/staff.html`, sign in with Google (or email), add your **pools** first.
2. Each coach adds **availability** so the shared calendar shows who can teach when.
3. Use **Publish Slots** to post bookable times (date, start time, length, how many back-to-back slots, pool, coach, price — prefilled with the default an admin sets on the Revenue tab).
4. Customers book on `/book.html` — a weekly calendar they can filter by pool, coach, day, and time of day. Booked slots vanish instantly. Every booking automatically creates/updates a client record in the **Clients** tab (searchable, with booking history and notes).

## How client data is protected

- **Bookings are invisible to the public.** Row Level Security blocks all anonymous reads of the bookings table — customer emails/phones are only visible to logged-in staff.
- **Booking happens only through a locked-down database function** that validates the email/phone, limits each email to 3 upcoming bookings (anti-spam), and uses a row lock + unique index so two people can never book the same slot, even clicking at the same instant.
- **Cancellations use a private token** shown once after booking — no one can cancel (or discover) someone else's booking.
- **Anyone can sign in with Google, but only allowlisted staff get access.** Every Row Level Security policy checks the signed-in email against the `staff_emails` table (via the `is_staff()` database function), so a random Google account can't read bookings or touch pools/slots/availability even by calling the API directly. The dashboard also signs such accounts out with "This account is not authorized as staff."
- **Client records are staff-only.** The `clients` table has no anonymous access at all; rows are created only inside the `book_slot` function.
- **Revenue is admins-only, enforced in the database.** Slot prices have no API read permission for anyone (column-level grants), and revenue comes only from `get_revenue_report()`, which raises an error unless the caller's profile has `role = 'admin'`. Coaches can set a price when publishing slots but can't read prices back in bulk, and the `role` column itself can't be written through the API.
- Everything runs over HTTPS on Supabase/GitHub Pages/Netlify.

## Weekly routine

Every week: staff open **Publish Slots**, enter that week's times per pool, done. Customers rebook from the same link. You can also duplicate a whole week quickly by re-entering the same form with a new date.

## Ideas for later

- **Email confirmations:** add a Supabase Edge Function + free [Resend](https://resend.com) account to auto-email the cancel link.
- **Coach photos:** add a `photo_url` column to `profiles` and an `<img>` in `index.html`.
- **Group lessons:** add a `capacity` column to slots and adjust `book_slot` to count bookings instead of flipping status.
- **Chinese translation:** duplicate `book.html` as `book-zh.html` for the WeChat group.

## Troubleshooting

- **Red banner on every page** → `config.js` still has placeholder values, or the URL/key are wrong. The banner text says which.
- **"Could not load slots"** → check `config.js` values, and that `schema.sql` ran without errors.
- **"This account is not authorized as staff"** → that email isn't in `staff_emails`. Add it in the SQL Editor (must match the Google account's email exactly, case doesn't matter).
- **"Could not verify staff access"** → `supabase/migration_google_auth.sql` hasn't been run on this project.
- **"Could not load settings" / empty Clients tab** → `supabase/migration_clients_revenue.sql` hasn't been run.
- **No Revenue tab after signing in** → your profile isn't an admin yet; run the `update public.profiles set role='admin'…` SQL from setup step 1.6.
- **Google button bounces back to the login page** → the page's URL isn't in **Authentication → URL Configuration → Additional Redirect URLs** (see step 2c), or the provider isn't enabled.
- **Google says "redirect_uri_mismatch"** → the Supabase callback URL is missing from the Google Cloud OAuth client's Authorized redirect URIs (step 2a).
- **New Google user can't sign in at all ("Signups not allowed")** → re-enable **Allow new users to sign up** (step 1.5); the allowlist is what keeps strangers out of the dashboard.
- **Email login fails** → confirm the user exists under Authentication → Users, and email/password sign-in is enabled.
- **Coach missing from dropdowns** → profiles are created automatically only for allowlisted emails; opening the dashboard once creates a missing profile. If it's still missing, insert a row into `profiles` manually.
