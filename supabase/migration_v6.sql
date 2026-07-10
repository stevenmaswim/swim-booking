-- ============================================================
-- Migration v6 — KSJ Swimming
-- Run AFTER all previous migrations (schema.sql → migration_google_auth.sql
-- → migration_clients_revenue.sql → migration_v3.sql → migration_v4.sql
-- → migration_security.sql → migration_v5.sql) in:
-- Supabase Dashboard > SQL Editor. Idempotent — safe to re-run.
--
--   1. bookings.cancelled_at + trigger (late-cancellation monitor;
--      informational only — nothing blocks cancelling).
--   2. admin_update_profile(): admins manage every coach profile,
--      including role, with a last-admin demotion guard.
--   3. (Weekly schedule export is frontend-only — no DB changes.)
--   4. Slot control: coaches may only publish slots assigned to
--      themselves; admin-only reopen_slot(); trigger clears the
--      public "Booked by" display whenever a slot leaves 'booked'.
--   5. get_revenue_grid(): admin-only revenue by hour-of-day × day-
--      of-week for a date range, grouped in the business timezone.
--   6. Multi-slot booking: book_slots() books 1–8 slots atomically
--      and requires email verification (6-digit code from the
--      existing booking_otps flow, or a 24h verification token).
--      The unverified single book_slot() is DROPPED — deploy the
--      new book.html at the same time you run this migration.
-- ============================================================

create extension if not exists pgcrypto with schema extensions;

-- ============================================================
-- 1. Late-cancellation monitor (staff visibility only)
-- ============================================================
alter table public.bookings add column if not exists cancelled_at timestamptz;

-- Set once, automatically, on ANY path that cancels a booking (client
-- token link, My Bookings, staff row update, bulk cancel, cancelled
-- slots). Historical cancellations stay null = "unknown" in the UI.
create or replace function public.set_booking_cancelled_at()
returns trigger
language plpgsql
as $$
begin
  if new.status = 'cancelled' and old.status is distinct from 'cancelled'
     and new.cancelled_at is null then
    new.cancelled_at := now();
  end if;
  return new;
end;
$$;

drop trigger if exists trg_booking_cancelled_at on public.bookings;
create trigger trg_booking_cancelled_at
  before update on public.bookings
  for each row execute function public.set_booking_cancelled_at();

-- Staff may only flip booking status via the API — cancelled_at (and
-- names/emails) can never be forged through a direct table write.
revoke insert, update, delete on table public.bookings from authenticated;
grant update (status) on public.bookings to authenticated;

-- ============================================================
-- 2. Admins manage all profiles
-- profiles.role has NO api write grant (by design, see
-- migration_clients_revenue.sql) and RLS only allows self-edit,
-- so admin management must be a SECURITY DEFINER RPC.
-- ============================================================
create or replace function public.admin_update_profile(
  p_id uuid,
  p_display_name text,
  p_bio text,
  p_is_public boolean,
  p_role text,
  p_photo_url text default null
) returns json
language plpgsql
security definer
set search_path = public
as $$
declare
  v_target public.profiles%rowtype;
  v_admins int;
begin
  if not public.is_admin() then
    raise exception 'Only admins can manage coach profiles.';
  end if;
  if p_display_name is null or length(trim(p_display_name)) < 1 then
    raise exception 'Display name cannot be empty.';
  end if;
  if p_role not in ('coach', 'admin') then
    raise exception 'Role must be coach or admin.';
  end if;

  select * into v_target from public.profiles where id = p_id for update;
  if not found then
    raise exception 'Profile not found.';
  end if;

  -- Never leave the site without an admin. (Only the caller can be the
  -- last admin — any other target being demoted implies the caller is a
  -- second admin — but guard generally for safety.)
  if v_target.role = 'admin' and p_role = 'coach' then
    select count(*) into v_admins from public.profiles where role = 'admin';
    if v_admins <= 1 then
      raise exception 'You are the last admin — promote someone else before demoting this account.';
    end if;
  end if;

  update public.profiles
  set display_name = trim(p_display_name),
      bio = coalesce(p_bio, ''),
      is_public = coalesce(p_is_public, false),
      role = p_role,
      photo_url = coalesce(p_photo_url, photo_url)
  where id = p_id;

  return json_build_object('ok', true);
end;
$$;

revoke all on function public.admin_update_profile(uuid, text, text, boolean, text, text) from public;
revoke execute on function public.admin_update_profile(uuid, text, text, boolean, text, text) from anon;
grant execute on function public.admin_update_profile(uuid, text, text, boolean, text, text) to authenticated;

-- ============================================================
-- 4. Slot control
-- ============================================================

-- 4a. Publish: coaches only for themselves; admins for anyone.
-- (Previously any staff could publish slots under any coach's name.)
drop policy if exists "staff publish slots" on public.slots;
drop policy if exists "publish own slots or admin" on public.slots;
create policy "publish own slots or admin" on public.slots
  for insert to authenticated
  with check (public.is_staff() and (public.is_admin() or coach_id = auth.uid()));

-- 4b. The public "Booked by First L." display must never survive a slot
-- leaving 'booked' (staff reopen previously left it stale).
create or replace function public.clear_booked_display()
returns trigger
language plpgsql
as $$
begin
  if old.status = 'booked' and new.status <> 'booked' then
    new.booked_by_display := null;
  end if;
  return new;
end;
$$;

drop trigger if exists trg_clear_booked_display on public.slots;
create trigger trg_clear_booked_display
  before update on public.slots
  for each row execute function public.clear_booked_display();

-- 4c. Reopen a cancelled slot — ADMIN ONLY (coaches ask an admin).
create or replace function public.reopen_slot(p_slot_id uuid)
returns json
language plpgsql
security definer
set search_path = public
as $$
declare
  v_slot public.slots%rowtype;
begin
  if not public.is_admin() then
    raise exception 'Only admins can reopen slots.';
  end if;

  select * into v_slot from public.slots where id = p_slot_id for update;
  if not found then
    raise exception 'Slot not found.';
  end if;
  if v_slot.status <> 'cancelled' then
    raise exception 'Only cancelled slots can be reopened.';
  end if;
  if v_slot.starts_at <= now() then
    raise exception 'This slot is in the past — publish a new one instead.';
  end if;
  if exists (select 1 from public.bookings
             where slot_id = p_slot_id and status = 'confirmed') then
    raise exception 'This slot still has a confirmed booking — cancel it first.';
  end if;

  update public.slots
  set status = 'open', booked_by_display = null
  where id = p_slot_id;

  return json_build_object('ok', true, 'starts_at', v_slot.starts_at);
end;
$$;

revoke all on function public.reopen_slot(uuid) from public;
revoke execute on function public.reopen_slot(uuid) from anon;
grant execute on function public.reopen_slot(uuid) to authenticated;

-- ============================================================
-- 5. Revenue by hour-of-day × day-of-week (admin only)
-- Hour/day are computed in the business timezone so the grid matches
-- the paper sheet regardless of where the admin's laptop is set.
-- ============================================================
create or replace function public.get_revenue_grid(
  p_from timestamptz,
  p_to timestamptz,
  p_tz text default 'America/Chicago'
) returns json
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_result json;
begin
  if not public.is_admin() then
    raise exception 'Only admins can view revenue.';
  end if;
  if p_from is null or p_to is null or p_to <= p_from then
    raise exception 'Please choose a valid date range.';
  end if;
  if p_to - p_from > interval '400 days' then
    raise exception 'Please choose a range of 400 days or less.';
  end if;
  begin
    perform now() at time zone p_tz;   -- raises for an unknown zone name
  exception when others then
    raise exception 'Unknown timezone: %', p_tz;
  end;

  select json_build_object(
    'cells', coalesce(json_agg(row_to_json(t)), '[]'::json)
  ) into v_result
  from (
    select extract(isodow from s.starts_at at time zone p_tz)::int as dow,  -- 1=Mon … 7=Sun
           extract(hour   from s.starts_at at time zone p_tz)::int as hour,
           count(*)::int as lessons,
           sum(s.price)  as revenue
    from public.bookings b
    join public.slots s on s.id = b.slot_id
    where b.status = 'confirmed'
      and s.starts_at >= p_from and s.starts_at < p_to
    group by 1, 2
  ) t;

  return v_result;
end;
$$;

revoke all on function public.get_revenue_grid(timestamptz, timestamptz, text) from public;
revoke execute on function public.get_revenue_grid(timestamptz, timestamptz, text) from anon;
grant execute on function public.get_revenue_grid(timestamptz, timestamptz, text) to authenticated;

-- ============================================================
-- 6. Multi-slot booking with email verification
-- ============================================================

-- 24h "verified email" tokens. The client stores the RAW token in
-- localStorage; only its sha256 lives here, so a DB leak can't be
-- replayed. Unreachable via the API — only book_slots() touches it.
create table if not exists public.booking_email_tokens (
  id uuid primary key default gen_random_uuid(),
  email text not null,
  token_hash text not null,
  expires_at timestamptz not null,
  created_at timestamptz not null default now()
);
create index if not exists booking_email_tokens_email_idx
  on public.booking_email_tokens (email, expires_at desc);
alter table public.booking_email_tokens enable row level security;
revoke all on table public.booking_email_tokens from anon, authenticated;

-- book_slots: the ONLY public path to create bookings from v6 on.
--   * verifies the email (6-digit code from booking_otps, or a live token)
--   * books 1–8 slots ATOMICALLY (any failure books nothing)
--   * row-locks slots in id order → no deadlocks between racing calls
--   * rejects overlaps against existing bookings AND within the new set
--   * cap: 8 upcoming confirmed bookings per email (raised from 3)
create or replace function public.book_slots(
  p_slot_ids uuid[],
  p_first_name text,
  p_last_name text,
  p_parent_name text,
  p_email text,
  p_phone text,
  p_code text default null,
  p_verify_token text default null,
  p_tz text default 'America/Chicago'
) returns json
language plpgsql
security definer
set search_path = public
as $$
declare
  v_ids uuid[];
  v_email text := lower(trim(coalesce(p_email, '')));
  v_first text := trim(coalesce(p_first_name, ''));
  v_last  text := trim(coalesce(p_last_name, ''));
  v_parent text := trim(coalesce(p_parent_name, ''));
  v_full text;
  v_display text;
  v_upcoming int;
  v_client_id uuid;
  v_otp public.booking_otps%rowtype;
  v_verified boolean := false;
  v_new_token text := null;
  v_slot public.slots%rowtype;
  v_booking public.bookings%rowtype;
  v_bad timestamptz;
  v_bookings jsonb := '[]'::jsonb;
  v_fmt text;
begin
  -- ---- basic validation (mirrors the old book_slot) ----
  if v_first = '' then raise exception 'Please enter the student''s first name.'; end if;
  if v_last  = '' then raise exception 'Please enter the student''s last name.'; end if;
  if length(v_parent) < 2 then raise exception 'Please enter the parent/guardian name.'; end if;
  if v_email !~ '^[^@\s]+@[^@\s]+\.[^@\s]+$' then
    raise exception 'Please enter a valid email address.';
  end if;
  if p_phone is null or length(regexp_replace(p_phone, '\D', '', 'g')) < 7 then
    raise exception 'Please enter a valid phone number.';
  end if;
  begin
    perform now() at time zone p_tz;
  exception when others then
    p_tz := 'America/Chicago';
  end;

  select array_agg(distinct u order by u) into v_ids
  from unnest(coalesce(p_slot_ids, '{}'::uuid[])) u;
  if v_ids is null or cardinality(v_ids) = 0 then
    raise exception 'Please select at least one lesson time.';
  end if;
  if cardinality(v_ids) > 8 then
    raise exception 'You can book at most 8 lessons at a time.';
  end if;

  -- ---- email verification: live 24h token, else the 6-digit code ----
  if p_verify_token is not null and length(trim(p_verify_token)) > 0 then
    select true into v_verified from public.booking_email_tokens
    where email = v_email and expires_at > now()
      and token_hash = encode(extensions.digest(trim(p_verify_token), 'sha256'), 'hex')
    limit 1;
    v_verified := coalesce(v_verified, false);
  end if;

  if not v_verified then
    if p_code is null or p_code !~ '^\d{6}$' then
      raise exception 'Please verify your email: request a code and enter the 6 digits.';
    end if;
    select * into v_otp from public.booking_otps
    where email = v_email and expires_at > now()
    order by created_at desc limit 1;
    if not found then
      raise exception 'No valid code found — please request a new one.';
    end if;
    if v_otp.attempts >= 5 then
      raise exception 'Too many attempts — please request a new code.';
    end if;
    if v_otp.code_hash <> encode(extensions.digest(p_code, 'sha256'), 'hex') then
      update public.booking_otps set attempts = attempts + 1 where id = v_otp.id;
      -- RETURN (not RAISE): an exception would roll back the attempts
      -- increment (PostgREST = one transaction per call), which would
      -- let wrong codes be retried forever. Returning commits it.
      return json_build_object('error', 'Incorrect code — please try again.');
    end if;
    v_verified := true;

    -- Issue a 24h skip-verification token (returned raw, stored hashed)
    v_new_token := replace(gen_random_uuid()::text, '-', '') ||
                   replace(gen_random_uuid()::text, '-', '');
    insert into public.booking_email_tokens (email, token_hash, expires_at)
    values (v_email, encode(extensions.digest(v_new_token, 'sha256'), 'hex'),
            now() + interval '24 hours');
    delete from public.booking_email_tokens where expires_at < now();  -- housekeeping
  end if;

  -- ---- cap: 8 upcoming confirmed bookings per email (incl. this set) ----
  select count(*) into v_upcoming
  from public.bookings b join public.slots s on s.id = b.slot_id
  where lower(b.email) = v_email
    and b.status = 'confirmed' and s.starts_at > now();
  if v_upcoming + cardinality(v_ids) > 8 then
    raise exception 'This would exceed 8 upcoming bookings for this email (you have %). Please contact us to book more.', v_upcoming;
  end if;

  v_full := v_first || ' ' || v_last;
  v_display := v_first || ' ' || upper(left(v_last, 1)) || '.';
  v_fmt := 'Dy Mon FMDD, FMHH12:MI AM';

  -- ---- lock ALL requested slots in id order (deadlock-free) ----
  perform 1 from public.slots where id = any(v_ids) order by id for update;

  -- Any slot missing, not open, or already started → book NOTHING,
  -- and name the offending time so the client knows which to re-pick.
  select s.starts_at into v_bad from public.slots s
  where s.id = any(v_ids) and (s.status <> 'open' or s.starts_at <= now())
  order by s.starts_at limit 1;
  if found then
    raise exception 'The % lesson was just taken or has passed — nothing was booked. Please pick a different time.',
      to_char(v_bad at time zone p_tz, v_fmt);
  end if;
  if (select count(*) from public.slots where id = any(v_ids)) <> cardinality(v_ids) then
    raise exception 'One of the selected lessons no longer exists — nothing was booked. Please refresh and try again.';
  end if;

  -- ---- overlap WITHIN the new set ----
  select s1.starts_at into v_bad
  from public.slots s1 join public.slots s2
    on s1.id < s2.id and s1.id = any(v_ids) and s2.id = any(v_ids)
  where s1.starts_at < s2.starts_at + make_interval(mins => s2.duration_min)
    and s2.starts_at < s1.starts_at + make_interval(mins => s1.duration_min)
  limit 1;
  if found then
    raise exception 'Two of your selected lessons overlap (around %) — please adjust your selection.',
      to_char(v_bad at time zone p_tz, v_fmt);
  end if;

  -- ---- overlap vs this email's EXISTING confirmed bookings ----
  select ns.starts_at into v_bad
  from public.slots ns
  join public.bookings b on b.status = 'confirmed' and lower(b.email) = v_email
  join public.slots s on s.id = b.slot_id and s.id <> all(v_ids)
  where ns.id = any(v_ids)
    and s.starts_at < ns.starts_at + make_interval(mins => ns.duration_min)
    and ns.starts_at < s.starts_at + make_interval(mins => s.duration_min)
  limit 1;
  if found then
    raise exception 'You already have a lesson booked that overlaps the % lesson.',
      to_char(v_bad at time zone p_tz, v_fmt);
  end if;

  -- ---- find-or-create the client, then book every slot ----
  insert into public.clients (name, first_name, last_name, parent_name, email, phone)
  values (v_full, v_first, v_last, v_parent, v_email, trim(p_phone))
  on conflict (email) do update
    set phone = excluded.phone,
        first_name = excluded.first_name,
        last_name = excluded.last_name,
        parent_name = excluded.parent_name,
        name = excluded.name
  returning id into v_client_id;

  for v_slot in
    select * from public.slots where id = any(v_ids) order by starts_at
  loop
    insert into public.bookings
      (slot_id, student_name, first_name, last_name, parent_name, email, phone, client_id)
    values
      (v_slot.id, v_full, v_first, v_last, v_parent, v_email, trim(p_phone), v_client_id)
    returning * into v_booking;
    v_bookings := v_bookings || jsonb_build_object(
      'booking_id', v_booking.id,
      'cancel_token', v_booking.cancel_token,
      'starts_at', v_slot.starts_at
    );
  end loop;

  update public.slots
  set status = 'booked', booked_by_display = v_display
  where id = any(v_ids);

  return json_build_object(
    'bookings', v_bookings,
    'verify_token', v_new_token   -- null when a still-valid token was used
  );
end;
$$;

revoke all on function public.book_slots(uuid[], text, text, text, text, text, text, text, text) from public;
grant execute on function public.book_slots(uuid[], text, text, text, text, text, text, text, text) to anon, authenticated;

-- The unverified single-slot path is gone: with it in place, the email
-- verification above could be bypassed by calling the old RPC directly.
-- (Deploy the new book.html at the same time as this migration.)
drop function if exists public.book_slot(uuid, text, text, text, text, text);

-- ============================================================
-- 7. SECURITY FIX: OTP attempt lockout never engaged (v4 bug).
-- verify_and_list_bookings incremented attempts and then RAISEd — but
-- PostgREST runs each RPC in a single transaction, so the exception
-- rolled the increment back and wrong codes could be retried forever.
-- Wrong-code now RETURNS {error: ...} so the increment commits.
-- (mybookings.html/book.html handle the returned error field.)
-- ============================================================
create or replace function public.verify_and_list_bookings(p_email text, p_code text)
returns json
language plpgsql security definer set search_path = public
as $$
declare
  v_email text := lower(trim(p_email));
  v_otp public.booking_otps%rowtype;
  v_result json;
begin
  select * into v_otp from public.booking_otps
  where email = v_email and expires_at > now()
  order by created_at desc limit 1;

  if not found then
    raise exception 'No valid code found — please request a new one.';
  end if;
  if v_otp.attempts >= 5 then
    raise exception 'Too many attempts — please request a new code.';
  end if;
  if v_otp.code_hash <> encode(extensions.digest(coalesce(p_code, ''), 'sha256'), 'hex') then
    update public.booking_otps set attempts = attempts + 1 where id = v_otp.id;
    return json_build_object('error', 'Incorrect code — please try again.');
  end if;

  -- Correct. Keep the code valid until it expires so the page can
  -- refresh the list after a cancellation without a new code.
  select json_agg(row_to_json(t)) into v_result from (
    select b.id, b.status, b.first_name, b.last_name, b.student_name,
           b.cancel_token, s.starts_at, s.duration_min,
           po.name as pool_name, po.address as pool_address,
           coalesce(pr.display_name, 'TBD') as coach
    from public.bookings b
    join public.slots s on s.id = b.slot_id
    join public.pools po on po.id = s.pool_id
    left join public.profiles pr on pr.id = s.coach_id
    where lower(b.email) = v_email
    order by s.starts_at desc
  ) t;

  return json_build_object('bookings', coalesce(v_result, '[]'::json));
end;
$$;
