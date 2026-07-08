-- ============================================================
-- Migration v5 — edit slots + history/export support
-- Run AFTER all previous migrations in: Supabase Dashboard > SQL Editor.
-- Idempotent — safe to re-run.
--
--   * get_slot_for_edit(): staff read one slot's editable fields
--     (incl. price, which is otherwise hidden) — gated to the slot's
--     coach or an admin.
--   * edit_slot(): change date/time/duration/pool/coach/price with the
--     no-overlap + no-past rules enforced in the DB (not just the UI).
--   CSV export + history are read-only and use existing staff RLS.
-- ============================================================

-- History/export scans slots by time — ensure the index exists.
create index if not exists slots_starts_at_idx on public.slots (starts_at);

-- ---------- Read one slot for editing (incl. price) ----------
create or replace function public.get_slot_for_edit(p_slot_id uuid)
returns json
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_slot public.slots%rowtype;
  v_book public.bookings%rowtype;
begin
  if not public.is_staff() then
    raise exception 'Not authorized.';
  end if;
  select * into v_slot from public.slots where id = p_slot_id;
  if not found then
    raise exception 'Slot not found.';
  end if;
  if not (public.is_admin() or v_slot.coach_id = auth.uid()) then
    raise exception 'You can only edit your own slots.';
  end if;

  select * into v_book from public.bookings
  where slot_id = p_slot_id and status = 'confirmed' limit 1;

  return json_build_object(
    'id', v_slot.id,
    'pool_id', v_slot.pool_id,
    'coach_id', v_slot.coach_id,
    'starts_at', v_slot.starts_at,
    'duration_min', v_slot.duration_min,
    'price', v_slot.price,
    'status', v_slot.status,
    'booking', case when v_book.id is not null then json_build_object(
        'id', v_book.id, 'first_name', v_book.first_name,
        'email', v_book.email, 'cancel_token', v_book.cancel_token
      ) else null end
  );
end;
$$;

revoke all on function public.get_slot_for_edit(uuid) from public;
revoke execute on function public.get_slot_for_edit(uuid) from anon;
grant execute on function public.get_slot_for_edit(uuid) to authenticated;

-- ---------- Edit a slot (coach: own only; admin: any) ----------
create or replace function public.edit_slot(
  p_slot_id uuid,
  p_starts_at timestamptz,
  p_duration_min int,
  p_pool_id uuid,
  p_coach_id uuid,
  p_price numeric
) returns json
language plpgsql
security definer
set search_path = public
as $$
declare
  v_slot public.slots%rowtype;
  v_book public.bookings%rowtype;
  v_uid uuid := auth.uid();
begin
  if not public.is_staff() then
    raise exception 'Not authorized.';
  end if;

  select * into v_slot from public.slots where id = p_slot_id for update;
  if not found then
    raise exception 'Slot not found.';
  end if;
  if not (public.is_admin() or v_slot.coach_id = v_uid) then
    raise exception 'You can only edit your own slots.';
  end if;
  -- A coach may not hand a slot to a different coach; admins may.
  if not public.is_admin() and p_coach_id is not null and p_coach_id <> v_uid then
    raise exception 'Coaches can only assign a slot to themselves.';
  end if;

  -- Validation
  if p_duration_min is null or p_duration_min < 15 or p_duration_min > 180 then
    raise exception 'Duration must be between 15 and 180 minutes.';
  end if;
  if p_price is null or p_price < 0 then
    raise exception 'Price must be 0 or more.';
  end if;
  if p_pool_id is null or not exists (select 1 from public.pools where id = p_pool_id) then
    raise exception 'Please choose a valid pool.';
  end if;
  if p_coach_id is not null and not exists (select 1 from public.profiles where id = p_coach_id) then
    raise exception 'Unknown coach.';
  end if;

  select * into v_book from public.bookings
  where slot_id = p_slot_id and status = 'confirmed' limit 1;

  -- Booked slots can't move into the past.
  if v_book.id is not null and p_starts_at <= now() then
    raise exception 'This lesson is booked — you can''t move it into the past.';
  end if;

  -- No-overlap: only matters when the slot is booked.
  if v_book.id is not null then
    -- Same client double-booked?
    if exists (
      select 1 from public.bookings b join public.slots s on s.id = b.slot_id
      where lower(b.email) = lower(v_book.email) and b.status = 'confirmed' and s.id <> p_slot_id
        and s.starts_at < p_starts_at + make_interval(mins => p_duration_min)
        and p_starts_at < s.starts_at + make_interval(mins => s.duration_min)
    ) then
      raise exception 'The client already has another lesson that overlaps this time.';
    end if;
    -- Same coach double-booked?
    if p_coach_id is not null and exists (
      select 1 from public.bookings b join public.slots s on s.id = b.slot_id
      where s.coach_id = p_coach_id and b.status = 'confirmed' and s.id <> p_slot_id
        and s.starts_at < p_starts_at + make_interval(mins => p_duration_min)
        and p_starts_at < s.starts_at + make_interval(mins => s.duration_min)
    ) then
      raise exception 'That coach already has another lesson that overlaps this time.';
    end if;
  end if;

  update public.slots
  set starts_at = p_starts_at, duration_min = p_duration_min,
      pool_id = p_pool_id, coach_id = p_coach_id, price = p_price
  where id = p_slot_id;

  return json_build_object(
    'ok', true,
    'booking', case when v_book.id is not null then json_build_object(
        'id', v_book.id, 'email', v_book.email,
        'first_name', v_book.first_name, 'cancel_token', v_book.cancel_token
      ) else null end
  );
end;
$$;

revoke all on function public.edit_slot(uuid, timestamptz, int, uuid, uuid, numeric) from public;
revoke execute on function public.edit_slot(uuid, timestamptz, int, uuid, uuid, numeric) from anon;
grant execute on function public.edit_slot(uuid, timestamptz, int, uuid, uuid, numeric) to authenticated;
