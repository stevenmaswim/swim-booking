-- ============================================================
-- Migration v10 — KSJ Swimming
-- Run AFTER migration_v9.sql in: Supabase Dashboard > SQL Editor.
-- Idempotent — safe to re-run.
--
-- BULK RAIN-OUT GETS A TIME WINDOW. Weather is not all-day: it can
-- pour at 9 AM and clear by 2 PM. Single slots could always be rained
-- out individually; the bulk tool could only take a whole day. It now
-- accepts an optional [from, until) time window in the pool's local
-- time — leave both null for the old whole-day behaviour.
--
-- The old 4-arg signature is DROPPED (a defaulted-params overload
-- would make PostgREST calls ambiguous).
-- ============================================================

drop function if exists public.rain_out_day(date, uuid, boolean, text);

create or replace function public.rain_out_day(
  p_day date,
  p_pool_id uuid default null,
  p_dry_run boolean default false,
  p_tz text default 'America/Chicago',
  p_from_time time default null,   -- e.g. '12:00' → only lessons from noon
  p_to_time time default null      -- e.g. '17:00' → …up to (not incl.) 5 PM
) returns json
language plpgsql
security definer
set search_path = public
as $$
declare
  v_open int;
  v_booked int;
  v_booking_ids jsonb;
begin
  if not public.is_admin() then
    raise exception 'Only admins can rain out a whole day.';
  end if;
  begin
    perform now() at time zone p_tz;
  exception when others then
    raise exception 'Unknown timezone: %', p_tz;
  end;
  if p_day is null or p_day < (now() at time zone p_tz)::date - 1 then
    raise exception 'Pick today, yesterday, or a future date.';
  end if;
  if p_from_time is not null and p_to_time is not null and p_from_time >= p_to_time then
    raise exception 'The "from" time must be before the "until" time.';
  end if;

  select count(*) filter (where status = 'open'),
         count(*) filter (where status = 'booked')
  into v_open, v_booked
  from public.slots
  where (starts_at at time zone p_tz)::date = p_day
    and status in ('open', 'booked')
    and (p_pool_id is null or pool_id = p_pool_id)
    and (p_from_time is null or (starts_at at time zone p_tz)::time >= p_from_time)
    and (p_to_time is null or (starts_at at time zone p_tz)::time < p_to_time);

  if p_dry_run then
    return json_build_object('dry_run', true, 'open', v_open, 'booked', v_booked);
  end if;

  -- Mark bookings first (they reference slots still in open/booked state)
  with affected as (
    select id from public.slots
    where (starts_at at time zone p_tz)::date = p_day
      and status in ('open', 'booked')
      and (p_pool_id is null or pool_id = p_pool_id)
      and (p_from_time is null or (starts_at at time zone p_tz)::time >= p_from_time)
      and (p_to_time is null or (starts_at at time zone p_tz)::time < p_to_time)
    for update
  ), b as (
    update public.bookings set status = 'rained_out'
    where slot_id in (select id from affected) and status = 'confirmed'
    returning id
  ), s as (
    update public.slots
    set status = 'rained_out', rained_out_at = now(), rained_out_by = auth.uid()
    where id in (select id from affected)
    returning 1
  )
  select coalesce(jsonb_agg(b.id), '[]'::jsonb) into v_booking_ids from b;

  return json_build_object(
    'dry_run', false, 'open', v_open, 'booked', v_booked,
    'booking_ids', v_booking_ids
  );
end;
$$;

revoke all on function public.rain_out_day(date, uuid, boolean, text, time, time) from public;
revoke execute on function public.rain_out_day(date, uuid, boolean, text, time, time) from anon;
grant execute on function public.rain_out_day(date, uuid, boolean, text, time, time) to authenticated;
