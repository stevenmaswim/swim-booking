-- ============================================================
-- Migration: client tracking (CRM) + revenue tracking
-- Run AFTER schema.sql and migration_google_auth.sql in:
-- Supabase Dashboard > SQL Editor
--
-- Adds:
--   1. clients table; book_slot finds-or-creates a client per
--      booking (by email, case-insensitive) and links bookings.
--   2. profiles.role ('coach' default | 'admin'), slots.price,
--      settings.default_price, and an admin-only revenue report
--      RPC. Price/revenue are unreadable to coaches — enforced
--      with column-level grants + a security definer RPC, not UI.
-- ============================================================

-- ---------- 1. Clients (CRM) ----------
create table public.clients (
  id uuid primary key default gen_random_uuid(),
  name text not null,
  email text not null unique,   -- always stored lowercase
  phone text not null default '',
  notes text not null default '',
  created_at timestamptz not null default now()
);

alter table public.clients enable row level security;

-- Staff can view all clients and edit notes. Anonymous users have no
-- policy at all — they can never read the clients table.
create policy "staff read clients" on public.clients
  for select to authenticated using (public.is_staff());
create policy "staff edit clients" on public.clients
  for update to authenticated
  using (public.is_staff()) with check (public.is_staff());

-- Rows are created only by the book_slot function (definer). Staff edits
-- via the API are limited to the notes column.
revoke insert, update, delete on table public.clients from anon, authenticated;
revoke select on table public.clients from anon;
grant update (notes) on public.clients to authenticated;

-- Link bookings to clients
alter table public.bookings add column client_id uuid references public.clients (id);
create index bookings_client_id_idx on public.bookings (client_id);

-- Backfill: one client per distinct email, keeping the most recent
-- name/phone seen (bookings.email is already stored lowercase).
insert into public.clients (name, email, phone)
select distinct on (lower(b.email)) b.student_name, lower(b.email), b.phone
from public.bookings b
order by lower(b.email), b.created_at desc
on conflict (email) do nothing;

update public.bookings b
set client_id = c.id
from public.clients c
where c.email = lower(b.email) and b.client_id is null;

-- ---------- 2. Roles, prices, settings ----------
alter table public.profiles add column role text not null default 'coach'
  check (role in ('coach', 'admin'));

-- Promote an admin (SQL editor only — the role column cannot be written
-- through the API at all, see grants below):
--   update public.profiles set role = 'admin' where id = '<user-uuid>';

alter table public.slots add column price numeric(8,2) not null default 0
  check (price >= 0);

-- ---------- is_admin() ----------
-- Defined before the settings policies below, which reference it.
create or replace function public.is_admin()
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select exists (
    select 1 from public.profiles
    where id = auth.uid() and role = 'admin'
  );
$$;

revoke all on function public.is_admin() from public;
grant execute on function public.is_admin() to authenticated;

create table public.settings (
  id smallint primary key default 1 check (id = 1),  -- single row
  default_price numeric(8,2) not null default 50
);
insert into public.settings (id) values (1);

alter table public.settings enable row level security;
-- Coaches read the default so the publish form can prefill it;
-- only admins may change it. No anonymous access.
create policy "staff read settings" on public.settings
  for select to authenticated using (public.is_staff());
create policy "admins update settings" on public.settings
  for update to authenticated
  using (public.is_admin()) with check (public.is_admin());
revoke insert, update, delete on table public.settings from anon, authenticated;
revoke select on table public.settings from anon;
grant update (default_price) on public.settings to authenticated;

-- ---------- Column-level lockdown ----------
-- profiles.role: RLS lets staff update their own row, but row-level
-- security can't stop them setting role='admin' on it. Column grants
-- can: the API may only ever write these profile columns.
revoke insert, update on table public.profiles from anon, authenticated;
grant insert (id, display_name, bio, is_public) on public.profiles to authenticated;
grant update (display_name, bio, is_public) on public.profiles to authenticated;

-- slots.price: coaches set a price when publishing (insert) but can
-- never read prices back in bulk — price is excluded from the select
-- grant. Revenue numbers only come out of get_revenue_report() below.
revoke select, insert, update, delete on table public.slots from anon, authenticated;
grant select (id, pool_id, coach_id, starts_at, duration_min, status, created_by, created_at)
  on public.slots to anon, authenticated;
grant insert (pool_id, coach_id, starts_at, duration_min, status, created_by, price)
  on public.slots to authenticated;
grant update (pool_id, coach_id, starts_at, duration_min, status)
  on public.slots to authenticated;

-- ---------- book_slot v2: find-or-create the client ----------
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
  v_client_id uuid;
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

  -- Find-or-create the client by email (case-insensitive). Phone is
  -- refreshed on every booking; the name is kept from first contact
  -- because per-booking student names (e.g. kids) live on the booking.
  insert into public.clients (name, email, phone)
  values (trim(p_name), lower(trim(p_email)), trim(p_phone))
  on conflict (email) do update set phone = excluded.phone
  returning id into v_client_id;

  -- Lock the slot row to prevent double booking
  select * into v_slot from public.slots
  where id = p_slot_id for update;

  if not found or v_slot.status <> 'open' or v_slot.starts_at <= now() then
    raise exception 'Sorry, this slot is no longer available.';
  end if;

  insert into public.bookings (slot_id, student_name, email, phone, client_id)
  values (p_slot_id, trim(p_name), lower(trim(p_email)), trim(p_phone), v_client_id)
  returning * into v_booking;

  update public.slots set status = 'booked' where id = p_slot_id;

  return json_build_object(
    'booking_id', v_booking.id,
    'cancel_token', v_booking.cancel_token,
    'starts_at', v_slot.starts_at
  );
end;
$$;

-- ---------- Revenue report (admins only, enforced here) ----------
create or replace function public.get_revenue_report(p_period text default 'week')
returns json
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
  if p_period not in ('week', 'month') then
    raise exception 'period must be ''week'' or ''month''';
  end if;

  select json_build_object(
    'total_lessons', (select count(*) from public.bookings b
                      join public.slots s on s.id = b.slot_id
                      where b.status = 'confirmed'),
    'total_revenue', (select coalesce(sum(s.price), 0) from public.bookings b
                      join public.slots s on s.id = b.slot_id
                      where b.status = 'confirmed'),
    'by_period', (select coalesce(json_agg(row_to_json(t)), '[]'::json) from (
        select date_trunc(p_period, s.starts_at) as period,
               count(*) as lessons,
               sum(s.price) as revenue
        from public.bookings b join public.slots s on s.id = b.slot_id
        where b.status = 'confirmed'
        group by 1 order by 1 desc limit 26) t),
    'by_coach', (select coalesce(json_agg(row_to_json(t)), '[]'::json) from (
        select coalesce(p.display_name, 'Unassigned') as coach,
               count(*) as lessons,
               sum(s.price) as revenue
        from public.bookings b
        join public.slots s on s.id = b.slot_id
        left join public.profiles p on p.id = s.coach_id
        where b.status = 'confirmed'
        group by 1 order by 3 desc) t),
    'by_pool', (select coalesce(json_agg(row_to_json(t)), '[]'::json) from (
        select po.name as pool,
               count(*) as lessons,
               sum(s.price) as revenue
        from public.bookings b
        join public.slots s on s.id = b.slot_id
        join public.pools po on po.id = s.pool_id
        where b.status = 'confirmed'
        group by 1 order by 3 desc) t)
  ) into v_result;

  return v_result;
end;
$$;

revoke all on function public.get_revenue_report(text) from public;
grant execute on function public.get_revenue_report(text) to authenticated;
