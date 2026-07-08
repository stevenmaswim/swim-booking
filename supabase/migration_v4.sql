-- ============================================================
-- Migration v4 — KSJ Swimming
-- Run AFTER schema.sql, migration_google_auth.sql,
-- migration_clients_revenue.sql and migration_v3.sql in:
-- Supabase Dashboard > SQL Editor
--
--   1. Split booking name into first/last + add internal-only
--      parent/guardian name (bookings + clients).
--   2. Public "FirstName L." on booked slots via a single column
--      (slots.booked_by_display) — never the bookings row.
--   3. Client self-service: one-time email codes (booking_otps)
--      and verify_and_list_bookings() so a client can see only
--      their own bookings after proving their email.
--   4. reminded_at on bookings + hourly pg_cron reminder job.
--   5. Revenue report gains a per-year view and a coach filter.
-- ============================================================

create extension if not exists pgcrypto with schema extensions;

-- ---------- 1. First / last / parent names ----------
alter table public.bookings add column if not exists first_name  text not null default '';
alter table public.bookings add column if not exists last_name   text not null default '';
alter table public.bookings add column if not exists parent_name text not null default '';  -- INTERNAL: staff-only
alter table public.bookings add column if not exists reminded_at timestamptz;               -- set once a reminder is sent

alter table public.clients add column if not exists first_name  text not null default '';
alter table public.clients add column if not exists last_name   text not null default '';
alter table public.clients add column if not exists parent_name text not null default '';

-- Best-effort backfill: split the existing full name on the first space.
-- A single-word name (no space) leaves last_name as '' (not null) — the
-- trim() already yields '' in that case, so no nullif here.
update public.bookings
set first_name = split_part(student_name, ' ', 1),
    last_name  = trim(substr(student_name, length(split_part(student_name, ' ', 1)) + 1))
where first_name = '';
update public.clients
set first_name = split_part(name, ' ', 1),
    last_name  = trim(substr(name, length(split_part(name, ' ', 1)) + 1))
where first_name = '';

-- ---------- 2. Public display string on booked slots ----------
-- Holds ONLY "FirstName L." while a slot is booked; null otherwise.
-- Exposed to anon via a column grant (never the bookings row). Set by
-- book_slot, cleared by cancel_booking.
alter table public.slots add column if not exists booked_by_display text;
grant select (booked_by_display) on public.slots to anon, authenticated;

-- ---------- 3. book_slot v4: first/last/parent + public display ----------
drop function if exists public.book_slot(uuid, text, text, text);

create or replace function public.book_slot(
  p_slot_id uuid,
  p_first_name text,
  p_last_name text,
  p_parent_name text,
  p_email text,
  p_phone text
) returns json
language plpgsql security definer set search_path = public
as $$
declare
  v_slot public.slots%rowtype;
  v_booking public.bookings%rowtype;
  v_upcoming int;
  v_client_id uuid;
  v_first text := trim(p_first_name);
  v_last  text := trim(p_last_name);
  v_parent text := trim(coalesce(p_parent_name, ''));
  v_full  text;
  v_display text;
begin
  -- Validation
  if v_first is null or length(v_first) < 1 then
    raise exception 'Please enter the student''s first name.';
  end if;
  if v_last is null or length(v_last) < 1 then
    raise exception 'Please enter the student''s last name.';
  end if;
  if v_parent is null or length(v_parent) < 2 then
    raise exception 'Please enter the parent/guardian name.';
  end if;
  if p_email is null or p_email !~ '^[^@\s]+@[^@\s]+\.[^@\s]+$' then
    raise exception 'Please enter a valid email address.';
  end if;
  if p_phone is null or length(regexp_replace(p_phone, '\D', '', 'g')) < 7 then
    raise exception 'Please enter a valid phone number.';
  end if;

  v_full := v_first || ' ' || v_last;
  v_display := v_first || ' ' || upper(left(v_last, 1)) || '.';

  -- Rate limit: max 3 upcoming confirmed bookings per email
  select count(*) into v_upcoming
  from public.bookings b join public.slots s on s.id = b.slot_id
  where lower(b.email) = lower(trim(p_email))
    and b.status = 'confirmed' and s.starts_at > now();
  if v_upcoming >= 3 then
    raise exception 'This email already has 3 upcoming bookings. Please contact us to book more.';
  end if;

  -- Find-or-create the client by email (case-insensitive)
  insert into public.clients (name, first_name, last_name, parent_name, email, phone)
  values (v_full, v_first, v_last, v_parent, lower(trim(p_email)), trim(p_phone))
  on conflict (email) do update
    set phone = excluded.phone,
        first_name = excluded.first_name,
        last_name = excluded.last_name,
        parent_name = excluded.parent_name,
        name = excluded.name
  returning id into v_client_id;

  -- Lock the slot row to prevent double booking
  select * into v_slot from public.slots
  where id = p_slot_id for update;

  if not found or v_slot.status <> 'open' or v_slot.starts_at <= now() then
    raise exception 'Sorry, this slot is no longer available.';
  end if;

  -- Reject a second lesson that overlaps this one in time
  if exists (
    select 1 from public.bookings b
    join public.slots s on s.id = b.slot_id
    where lower(b.email) = lower(trim(p_email))
      and b.status = 'confirmed'
      and s.id <> v_slot.id
      and s.starts_at < v_slot.starts_at + make_interval(mins => v_slot.duration_min)
      and v_slot.starts_at < s.starts_at + make_interval(mins => s.duration_min)
  ) then
    raise exception 'You already have a lesson booked at this time.';
  end if;

  insert into public.bookings
    (slot_id, student_name, first_name, last_name, parent_name, email, phone, client_id)
  values
    (p_slot_id, v_full, v_first, v_last, v_parent, lower(trim(p_email)), trim(p_phone), v_client_id)
  returning * into v_booking;

  update public.slots
  set status = 'booked', booked_by_display = v_display
  where id = p_slot_id;

  return json_build_object(
    'booking_id', v_booking.id,
    'cancel_token', v_booking.cancel_token,
    'starts_at', v_slot.starts_at
  );
end;
$$;

revoke all on function public.book_slot(uuid, text, text, text, text, text) from public;
grant execute on function public.book_slot(uuid, text, text, text, text, text) to anon, authenticated;

-- ---------- Clear the public display when a slot reopens ----------
create or replace function public.cancel_booking(p_token uuid)
returns json
language plpgsql security definer set search_path = public
as $$
declare
  v_booking public.bookings%rowtype;
  v_slot public.slots%rowtype;
begin
  select b.* into v_booking from public.bookings b
  join public.slots s on s.id = b.slot_id
  where b.cancel_token = p_token and b.status = 'confirmed'
    and s.starts_at > now()
  for update;

  if not found then
    raise exception 'Booking not found, already cancelled, or already in the past.';
  end if;

  update public.bookings set status = 'cancelled' where id = v_booking.id;
  update public.slots set status = 'open', booked_by_display = null
  where id = v_booking.slot_id
  returning * into v_slot;

  return json_build_object('cancelled', true, 'starts_at', v_slot.starts_at);
end;
$$;

-- ---------- 4. Client self-service login codes (OTP) ----------
create table if not exists public.booking_otps (
  id uuid primary key default gen_random_uuid(),
  email text not null,
  code_hash text not null,          -- sha256 hex of the 6-digit code
  attempts int not null default 0,
  expires_at timestamptz not null,
  created_at timestamptz not null default now()
);
create index if not exists booking_otps_email_idx on public.booking_otps (email, created_at desc);

-- No policies + revoked grants: only the service role (Edge Function)
-- and the security definer verify function below ever touch this table.
alter table public.booking_otps enable row level security;
revoke all on table public.booking_otps from anon, authenticated;

-- Verify a code and, if correct, return ONLY this email's bookings.
-- Anonymous callers can never read the bookings table directly; this
-- is the single gated path and it returns no parent name or phone.
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
    raise exception 'Incorrect code — please try again.';
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

revoke all on function public.verify_and_list_bookings(text, text) from public;
grant execute on function public.verify_and_list_bookings(text, text) to anon, authenticated;

-- ---------- 5. Revenue report v2: per-year view + coach filter ----------
drop function if exists public.get_revenue_report(text);

create or replace function public.get_revenue_report(
  p_period text default 'week',
  p_year int default null,
  p_coach_id uuid default null
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
  if p_period not in ('week', 'month', 'year') then
    raise exception 'period must be ''week'', ''month'' or ''year''';
  end if;

  select json_build_object(
    'total_lessons', (select count(*) from public.bookings b
        join public.slots s on s.id = b.slot_id
        where b.status = 'confirmed'
          and (p_coach_id is null or s.coach_id = p_coach_id)
          and (p_year is null or extract(year from s.starts_at) = p_year)),
    'total_revenue', (select coalesce(sum(s.price), 0) from public.bookings b
        join public.slots s on s.id = b.slot_id
        where b.status = 'confirmed'
          and (p_coach_id is null or s.coach_id = p_coach_id)
          and (p_year is null or extract(year from s.starts_at) = p_year)),
    -- distinct years that have confirmed bookings (for the year picker)
    'years', (select coalesce(json_agg(y order by y desc), '[]'::json) from (
        select distinct extract(year from s.starts_at)::int as y
        from public.bookings b join public.slots s on s.id = b.slot_id
        where b.status = 'confirmed') yr),
    'by_period', (select coalesce(json_agg(row_to_json(t)), '[]'::json) from (
        select date_trunc(p_period, s.starts_at) as period,
               count(*) as lessons,
               sum(s.price) as revenue
        from public.bookings b join public.slots s on s.id = b.slot_id
        where b.status = 'confirmed'
          and (p_coach_id is null or s.coach_id = p_coach_id)
          and (p_year is null or extract(year from s.starts_at) = p_year)
        group by 1 order by 1 desc limit 60) t),
    'by_coach', (select coalesce(json_agg(row_to_json(t)), '[]'::json) from (
        select coalesce(p.display_name, 'Unassigned') as coach,
               count(*) as lessons,
               sum(s.price) as revenue
        from public.bookings b
        join public.slots s on s.id = b.slot_id
        left join public.profiles p on p.id = s.coach_id
        where b.status = 'confirmed'
          and (p_coach_id is null or s.coach_id = p_coach_id)
          and (p_year is null or extract(year from s.starts_at) = p_year)
        group by 1 order by 3 desc) t),
    'by_pool', (select coalesce(json_agg(row_to_json(t)), '[]'::json) from (
        select po.name as pool,
               count(*) as lessons,
               sum(s.price) as revenue
        from public.bookings b
        join public.slots s on s.id = b.slot_id
        join public.pools po on po.id = s.pool_id
        where b.status = 'confirmed'
          and (p_coach_id is null or s.coach_id = p_coach_id)
          and (p_year is null or extract(year from s.starts_at) = p_year)
        group by 1 order by 3 desc) t)
  ) into v_result;

  return v_result;
end;
$$;

revoke all on function public.get_revenue_report(text, int, uuid) from public;
grant execute on function public.get_revenue_report(text, int, uuid) to authenticated;

-- ============================================================
-- 6. Hourly reminder job (pg_cron -> pg_net -> Edge Function).
-- Guarded so the whole migration never aborts if these extensions
-- aren't available on your plan — set them up per the README then.
--
-- BEFORE the reminders will work you MUST edit the __CRON_SECRET__
-- placeholder below to match the CRON_SECRET secret you set on the
-- Edge Function (README "Reminder emails"). Re-run just this block
-- after editing, or run it here with the real value.
-- ============================================================
do $$
begin
  create extension if not exists pg_net with schema extensions;
  create extension if not exists pg_cron;

  -- Replace any previous schedule of the same name
  perform cron.unschedule('ksj-lesson-reminders')
  where exists (select 1 from cron.job where jobname = 'ksj-lesson-reminders');

  perform cron.schedule(
    'ksj-lesson-reminders',
    '0 * * * *',   -- top of every hour
    $job$
      select net.http_post(
        url := 'https://jvzahjtoiwfsshgzsyym.supabase.co/functions/v1/emails',
        headers := jsonb_build_object(
          'Content-Type', 'application/json',
          'x-cron-secret', '__CRON_SECRET__'
        ),
        body := jsonb_build_object('type', 'reminders')
      );
    $job$
  );
exception when others then
  raise notice 'Reminder cron not scheduled (%). Enable pg_cron + pg_net and run the DO block per the README.', sqlerrm;
end $$;
