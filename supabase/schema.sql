-- ============================================================
-- Swim Lessons Booking — Supabase schema
-- Run this whole file once in: Supabase Dashboard > SQL Editor
-- ============================================================

-- ---------- Coach profiles (one per staff login) ----------
create table public.profiles (
  id uuid primary key references auth.users (id) on delete cascade,
  display_name text not null,
  bio text not null default '',
  is_public boolean not null default true,  -- show on "About the Coaches"
  created_at timestamptz not null default now()
);

-- Auto-create a profile whenever a staff user is added in the dashboard
create or replace function public.handle_new_user()
returns trigger
language plpgsql security definer set search_path = public
as $$
begin
  insert into public.profiles (id, display_name)
  values (new.id, coalesce(new.raw_user_meta_data->>'name', split_part(new.email, '@', 1)));
  return new;
end;
$$;

create trigger on_auth_user_created
  after insert on auth.users
  for each row execute function public.handle_new_user();

-- ---------- Pools ----------
create table public.pools (
  id uuid primary key default gen_random_uuid(),
  name text not null,
  address text not null default '',
  notes text not null default '',
  active boolean not null default true,
  created_at timestamptz not null default now()
);

-- ---------- Coach availability (for the staff calendar) ----------
create table public.availability (
  id uuid primary key default gen_random_uuid(),
  coach_id uuid not null references public.profiles (id) on delete cascade,
  day date not null,
  start_time time not null,
  end_time time not null,
  pool_id uuid references public.pools (id) on delete set null,
  note text not null default '',
  created_at timestamptz not null default now(),
  check (end_time > start_time)
);

-- ---------- Bookable slots (published manually by staff) ----------
create table public.slots (
  id uuid primary key default gen_random_uuid(),
  pool_id uuid not null references public.pools (id),
  coach_id uuid references public.profiles (id) on delete set null,
  starts_at timestamptz not null,
  duration_min int not null default 30 check (duration_min between 15 and 180),
  status text not null default 'open' check (status in ('open', 'booked', 'cancelled')),
  created_by uuid references public.profiles (id),
  created_at timestamptz not null default now()
);
create index slots_starts_at_idx on public.slots (starts_at);

-- ---------- Bookings (client data — locked down) ----------
create table public.bookings (
  id uuid primary key default gen_random_uuid(),
  slot_id uuid not null references public.slots (id) on delete cascade,
  student_name text not null,
  email text not null,
  phone text not null,
  status text not null default 'confirmed' check (status in ('confirmed', 'cancelled')),
  cancel_token uuid not null default gen_random_uuid(),
  created_at timestamptz not null default now()
);
-- One confirmed booking per slot, enforced at the database level
create unique index one_confirmed_booking_per_slot
  on public.bookings (slot_id) where (status = 'confirmed');

-- ============================================================
-- Row Level Security
-- Anonymous visitors: can see pools, public coach names, and OPEN
-- future slots. They can NEVER read bookings (client data).
-- Staff (any authenticated user): full access.
-- ============================================================
alter table public.profiles     enable row level security;
alter table public.pools        enable row level security;
alter table public.availability enable row level security;
alter table public.slots        enable row level security;
alter table public.bookings     enable row level security;

-- Profiles
create policy "public coach cards" on public.profiles
  for select using (is_public = true);
create policy "staff read all profiles" on public.profiles
  for select to authenticated using (true);
create policy "staff edit own profile" on public.profiles
  for update to authenticated using (id = auth.uid());

-- Pools
create policy "public sees active pools" on public.pools
  for select using (active = true);
create policy "staff manage pools" on public.pools
  for all to authenticated using (true) with check (true);

-- Availability (staff-only; not visible to the public)
create policy "staff read availability" on public.availability
  for select to authenticated using (true);
create policy "staff manage own availability" on public.availability
  for all to authenticated using (coach_id = auth.uid()) with check (coach_id = auth.uid());

-- Slots
create policy "public sees open future slots" on public.slots
  for select using (status = 'open' and starts_at > now());
create policy "staff manage slots" on public.slots
  for all to authenticated using (true) with check (true);

-- Bookings: NO anonymous access at all. Staff read/update only.
create policy "staff read bookings" on public.bookings
  for select to authenticated using (true);
create policy "staff update bookings" on public.bookings
  for update to authenticated using (true) with check (true);

-- ============================================================
-- book_slot: the ONLY way anonymous users can create a booking.
-- Atomic (row lock + unique index), validates input, rate-limits
-- to 3 upcoming bookings per email.
-- ============================================================
create or replace function public.book_slot(
  p_slot_id uuid,
  p_name text,
  p_email text,
  p_phone text
) returns json
language plpgsql security definer set search_path = public
as $$
declare
  v_slot public.slots%rowtype;
  v_booking public.bookings%rowtype;
  v_upcoming int;
begin
  -- Basic validation
  if p_name is null or length(trim(p_name)) < 2 then
    raise exception 'Please enter the student''s name.';
  end if;
  if p_email is null or p_email !~ '^[^@\s]+@[^@\s]+\.[^@\s]+$' then
    raise exception 'Please enter a valid email address.';
  end if;
  if p_phone is null or length(regexp_replace(p_phone, '\D', '', 'g')) < 7 then
    raise exception 'Please enter a valid phone number.';
  end if;

  -- Rate limit: max 3 upcoming confirmed bookings per email
  select count(*) into v_upcoming
  from public.bookings b join public.slots s on s.id = b.slot_id
  where lower(b.email) = lower(trim(p_email))
    and b.status = 'confirmed' and s.starts_at > now();
  if v_upcoming >= 3 then
    raise exception 'This email already has 3 upcoming bookings. Please contact us to book more.';
  end if;

  -- Lock the slot row to prevent double booking
  select * into v_slot from public.slots
  where id = p_slot_id for update;

  if not found or v_slot.status <> 'open' or v_slot.starts_at <= now() then
    raise exception 'Sorry, this slot is no longer available.';
  end if;

  insert into public.bookings (slot_id, student_name, email, phone)
  values (p_slot_id, trim(p_name), lower(trim(p_email)), trim(p_phone))
  returning * into v_booking;

  update public.slots set status = 'booked' where id = p_slot_id;

  return json_build_object(
    'booking_id', v_booking.id,
    'cancel_token', v_booking.cancel_token,
    'starts_at', v_slot.starts_at
  );
end;
$$;

-- Self-service cancellation using the private token from the confirmation
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
  update public.slots set status = 'open' where id = v_booking.slot_id
  returning * into v_slot;

  return json_build_object('cancelled', true, 'starts_at', v_slot.starts_at);
end;
$$;

-- Lock down function execution
revoke all on function public.book_slot(uuid, text, text, text) from public;
revoke all on function public.cancel_booking(uuid) from public;
grant execute on function public.book_slot(uuid, text, text, text) to anon, authenticated;
grant execute on function public.cancel_booking(uuid) to anon, authenticated;
