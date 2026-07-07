# Swim Lessons Booking Website

A booking site with no payment infrastructure. Customers with the link book a lesson with just name + email + phone. Staff log in to set availability, publish slots per pool, and see bookings.

**Cost to run: $0** (Supabase free tier + Netlify free tier).

## What's included

| File | Purpose |
|---|---|
| `index.html` | Public home page (About the Coaches + pools load automatically) |
| `book.html` | Customer booking page — share this link in your WeChat group |
| `staff.html` | Staff dashboard (login required) |
| `supabase/schema.sql` | Database, security rules, and booking logic |
| `config.js` | Your Supabase keys go here |
| `styles.css` | Shared styling |

## Setup (~15 minutes)

### 1. Create the backend (Supabase)
1. Go to [supabase.com](https://supabase.com) → sign up → **New project** (free tier). Pick a strong database password and a region near you.
2. In the dashboard, open **SQL Editor** → **New query** → paste the entire contents of `supabase/schema.sql` → **Run**.
3. Go to **Authentication → Sign In / Up** and **disable "Allow new users to sign up"**. Staff accounts are created manually (next step) — this stops strangers from creating staff logins.
4. Go to **Authentication → Users → Add user → Create new user** for each coach (email + password). A coach profile is created automatically.
5. Go to **Project Settings → API** (or “Data API”) and copy the **Project URL** and **anon public key**.

### 2. Configure the site
Open `config.js` and paste your two values:
```js
const SUPABASE_URL = "https://xxxx.supabase.co";
const SUPABASE_ANON_KEY = "eyJ...";
```
(The anon key is safe to publish — all protection comes from database Row Level Security.)

### 3. Deploy (Netlify)
1. Go to [app.netlify.com/drop](https://app.netlify.com/drop) and drag the whole `swim-booking` folder in.
2. You get a URL like `https://your-site.netlify.app`. Share `https://your-site.netlify.app/book.html` in your WeChat group.
3. (Optional) Add a custom domain later in Netlify settings.

### 4. First run
1. Open `/staff.html`, log in, add your **pools** first.
2. Each coach adds **availability** so the shared calendar shows who can teach when.
3. Use **Publish Slots** to post bookable times (date, start time, length, how many back-to-back slots, pool, coach).
4. Customers book on `/book.html`; booked slots vanish from the public page instantly.

## How client data is protected

- **Bookings are invisible to the public.** Row Level Security blocks all anonymous reads of the bookings table — customer emails/phones are only visible to logged-in staff.
- **Booking happens only through a locked-down database function** that validates the email/phone, limits each email to 3 upcoming bookings (anti-spam), and uses a row lock + unique index so two people can never book the same slot, even clicking at the same instant.
- **Cancellations use a private token** shown once after booking — no one can cancel (or discover) someone else's booking.
- **Staff signup is disabled**; only accounts you create in the dashboard can log in.
- Everything runs over HTTPS on Supabase/Netlify.

## Weekly routine

Every week: staff open **Publish Slots**, enter that week's times per pool, done. Customers rebook from the same link. You can also duplicate a whole week quickly by re-entering the same form with a new date.

## Ideas for later

- **Email confirmations:** add a Supabase Edge Function + free [Resend](https://resend.com) account to auto-email the cancel link.
- **Coach photos:** add a `photo_url` column to `profiles` and an `<img>` in `index.html`.
- **Group lessons:** add a `capacity` column to slots and adjust `book_slot` to count bookings instead of flipping status.
- **Chinese translation:** duplicate `book.html` as `book-zh.html` for the WeChat group.

## Troubleshooting

- **"Could not load slots"** → check `config.js` values, and that `schema.sql` ran without errors.
- **Login fails** → confirm the user exists under Authentication → Users, and email/password sign-in is enabled.
- **Coach missing from dropdowns** → the profile is created when the user is added; if you added users *before* running the SQL, insert a row into `profiles` manually.
