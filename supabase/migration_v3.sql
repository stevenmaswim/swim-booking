-- ============================================================
-- Migration v3 — KSJ Swimming
-- Run AFTER schema.sql, migration_google_auth.sql and
-- migration_clients_revenue.sql in: Supabase Dashboard > SQL Editor
--
--   1. Removes the availability feature (table + policies).
--   2. Adds photo_url to profiles/pools + a public "photos"
--      storage bucket (staff upload, everyone reads).
--   3. Anonymous visitors can now SEE future booked slots
--      (time/pool/coach only) so the public calendar shows the
--      schedule shape. Bookings/clients stay unreadable.
--   4. Coach vs admin permissions: coaches cancel only their own
--      slots/bookings; only admins edit clients or delete them
--      (delete anonymizes the client's past bookings).
--   5. book_slot rejects overlapping bookings for the same email.
-- ============================================================

-- ---------- 1. Availability feature removed ----------
drop table if exists public.availability;

-- ---------- 2. Photos ----------
alter table public.profiles add column photo_url text;
alter table public.pools add column photo_url text;
-- profiles writes are column-whitelisted; allow the new column
grant update (photo_url) on public.profiles to authenticated;

-- Storage bucket + policies. Guarded: on some Supabase projects the
-- SQL role can't run DDL against storage — if you see the NOTICE
-- below, create the bucket by hand (README "Photos bucket" section).
do $$
begin
  insert into storage.buckets (id, name, public)
  values ('photos', 'photos', true)
  on conflict (id) do update set public = true;

  begin
    create policy "photos public read" on storage.objects
      for select using (bucket_id = 'photos');
    create policy "photos staff upload" on storage.objects
      for insert to authenticated
      with check (bucket_id = 'photos' and public.is_staff());
    create policy "photos staff update" on storage.objects
      for update to authenticated
      using (bucket_id = 'photos' and public.is_staff())
      with check (bucket_id = 'photos' and public.is_staff());
    create policy "photos staff delete" on storage.objects
      for delete to authenticated
      using (bucket_id = 'photos' and public.is_staff());
  exception when duplicate_object then null;
  end;
exception when insufficient_privilege or undefined_table then
  raise notice 'Could not set up storage via SQL — create a public "photos" bucket in Dashboard > Storage instead (see README).';
end $$;

-- ---------- 3. Booked slots visible to the public ----------
-- Only the slot row (time/pool/coach/status). The price column has no
-- API select grant, and bookings/clients have no anonymous policies,
-- so no client data leaks.
drop policy "public sees open future slots" on public.slots;
create policy "public sees future slots" on public.slots
  for select using (status in ('open', 'booked') and starts_at > now());

-- ---------- 4a. Slots: coaches manage their own, admins manage all ----------
drop policy "staff manage slots" on public.slots;
create policy "staff read slots" on public.slots
  for select to authenticated using (public.is_staff());
create policy "staff publish slots" on public.slots
  for insert to authenticated with check (public.is_staff());
create policy "cancel own slots or admin" on public.slots
  for update to authenticated
  using (public.is_staff() and (public.is_admin() or coach_id = auth.uid()))
  with check (public.is_staff() and (public.is_admin() or coach_id = auth.uid()));

-- ---------- 4b. Bookings: cancel only on own slots unless admin ----------
drop policy "staff update bookings" on public.bookings;
create policy "staff update own bookings" on public.bookings
  for update to authenticated
  using (public.is_staff() and (public.is_admin() or exists (
    select 1 from public.slots s
    where s.id = slot_id and s.coach_id = auth.uid())))
  with check (public.is_staff() and (public.is_admin() or exists (
    select 1 from public.slots s
    where s.id = slot_id and s.coach_id = auth.uid())));

-- ---------- 4c. Clients: only admins edit; delete via RPC ----------
drop policy "staff edit clients" on public.clients;
create policy "admins edit clients" on public.clients
  for update to authenticated
  using (public.is_admin()) with check (public.is_admin());

-- Deleting a client anonymizes their bookings (history and revenue
-- keep working) and then removes the client row. Admin-only.
create or replace function public.delete_client(p_client_id uuid)
returns void
language plpgsql security definer set search_path = public
as $$
begin
  if not public.is_admin() then
    raise exception 'Only admins can delete clients.';
  end if;
  update public.bookings
  set student_name = '[deleted]',
      email = 'deleted+' || id::text || '@redacted.invalid',
      phone = '',
      client_id = null
  where client_id = p_client_id;
  delete from public.clients where id = p_client_id;
end;
$$;

revoke all on function public.delete_client(uuid) from public;
grant execute on function public.delete_client(uuid) to authenticated;

-- ---------- 5. book_slot v3: no overlapping booking per email ----------
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

  -- Find-or-create the client by email (case-insensitive)
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

  -- Reject a second lesson that overlaps this one in time
  -- ([start, start+duration) ranges intersect)
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
