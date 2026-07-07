-- ============================================================
-- Migration: Google sign-in + staff allowlist
-- Run AFTER schema.sql in: Supabase Dashboard > SQL Editor
--
-- Anyone with a Google account can SIGN IN, but only emails in
-- staff_emails may use the dashboard. This is enforced in the
-- database (RLS), not just in the UI.
-- ============================================================

-- ---------- Staff allowlist ----------
create table public.staff_emails (
  email text primary key
);

-- RLS on, and deliberately NO policies: the table is invisible to the
-- API for everyone. Only the security definer function below (and the
-- dashboard/SQL editor) can read it. Add staff with:
--   insert into public.staff_emails (email) values ('coach@example.com');
alter table public.staff_emails enable row level security;

-- ---------- is_staff(): is the current user's email allowlisted? ----------
create or replace function public.is_staff()
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select exists (
    select 1 from public.staff_emails
    where lower(email) = lower(coalesce(auth.jwt()->>'email', ''))
  );
$$;

revoke all on function public.is_staff() from public;
grant execute on function public.is_staff() to anon, authenticated;

-- ---------- Auto-created profiles ----------
-- Google sign-ups put the display name in raw_user_meta_data->>'full_name'
-- (dashboard-created users use 'name'). Only allowlisted emails get a
-- profile — random Google accounts must not appear as coaches. Staff
-- allowlisted *after* their first sign-in are handled by the dashboard,
-- which creates the missing profile on login (see insert policy below).
create or replace function public.handle_new_user()
returns trigger
language plpgsql security definer set search_path = public
as $$
begin
  if exists (select 1 from public.staff_emails
             where lower(email) = lower(new.email)) then
    insert into public.profiles (id, display_name)
    values (new.id, coalesce(
      nullif(trim(new.raw_user_meta_data->>'full_name'), ''),
      nullif(trim(new.raw_user_meta_data->>'name'), ''),
      split_part(new.email, '@', 1)))
    on conflict (id) do nothing;
  end if;
  return new;
end;
$$;

-- ============================================================
-- Tighten RLS: every policy that trusted "any authenticated user"
-- now also requires is_staff(). Public (anon) policies are unchanged
-- — anonymous visitors still can never read bookings.
-- ============================================================

-- Profiles
drop policy "staff read all profiles" on public.profiles;
create policy "staff read all profiles" on public.profiles
  for select to authenticated using (public.is_staff());

drop policy "staff edit own profile" on public.profiles;
create policy "staff edit own profile" on public.profiles
  for update to authenticated
  using (id = auth.uid() and public.is_staff())
  with check (id = auth.uid() and public.is_staff());

-- Lets an allowlisted staff member create their own missing profile
-- (e.g. they signed in with Google before being added to staff_emails).
create policy "staff create own profile" on public.profiles
  for insert to authenticated
  with check (id = auth.uid() and public.is_staff());

-- Pools
drop policy "staff manage pools" on public.pools;
create policy "staff manage pools" on public.pools
  for all to authenticated
  using (public.is_staff()) with check (public.is_staff());

-- Availability
drop policy "staff read availability" on public.availability;
create policy "staff read availability" on public.availability
  for select to authenticated using (public.is_staff());

drop policy "staff manage own availability" on public.availability;
create policy "staff manage own availability" on public.availability
  for all to authenticated
  using (coach_id = auth.uid() and public.is_staff())
  with check (coach_id = auth.uid() and public.is_staff());

-- Slots
drop policy "staff manage slots" on public.slots;
create policy "staff manage slots" on public.slots
  for all to authenticated
  using (public.is_staff()) with check (public.is_staff());

-- Bookings (still zero anonymous access)
drop policy "staff read bookings" on public.bookings;
create policy "staff read bookings" on public.bookings
  for select to authenticated using (public.is_staff());

drop policy "staff update bookings" on public.bookings;
create policy "staff update bookings" on public.bookings
  for update to authenticated
  using (public.is_staff()) with check (public.is_staff());
