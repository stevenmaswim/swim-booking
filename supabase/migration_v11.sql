-- ============================================================
-- Migration v11 — KSJ Swimming: RECENTLY CANCELLED + coach alerts
-- Run AFTER migration_v10.sql in: Supabase Dashboard > SQL Editor.
-- Idempotent — safe to re-run.
--
-- (The feature spec said "v10"; v10 was already taken by the rain-out
-- time window, so this is v11.)
--
-- Staff need to see slots that just freed up, and coaches want an email
-- when it happens. Two things the schema has to answer that it couldn't:
--
--   1. WHO cancelled? Client cancellations come through the anonymous
--      cancel_booking() RPC (auth.uid() is null); staff cancellations are
--      direct table updates carrying a staff JWT (auth.uid() is set). The
--      existing cancelled_at trigger now records that distinction in
--      bookings.cancelled_by ('client' | 'staff'). Rain-outs never reach
--      this path — they set status='rained_out', so they stay out of the
--      panel and never trigger an alert.
--   2. Has this cancellation already been emailed about? cancel_alert_sent_at
--      is claimed atomically by the Edge Function so a client cancelling
--      three lessons produces ONE email per coach, not three.
--
-- Plus per-coach notification toggles and a per-user "last viewed" stamp
-- (server-side so the unread badge follows staff across devices).
-- ============================================================

-- ---------- 1. Who cancelled, and has it been alerted ----------
alter table public.bookings add column if not exists cancelled_by text
  check (cancelled_by in ('client', 'staff'));
alter table public.bookings add column if not exists cancel_alert_sent_at timestamptz;

-- Neither column is writable through the API: bookings only grants
-- update(status) to authenticated (migration_v6), so these are set by the
-- trigger below and by the Edge Function's service role.

-- The panel reads "cancellations in the last 14 days, newest first".
create index if not exists bookings_cancelled_at_idx
  on public.bookings (cancelled_at desc)
  where status = 'cancelled';

create or replace function public.set_booking_cancelled_at()
returns trigger
language plpgsql
as $$
begin
  if new.status = 'cancelled' and old.status is distinct from 'cancelled' then
    if new.cancelled_at is null then
      new.cancelled_at := now();
    end if;
    if new.cancelled_by is null then
      -- anon (the client's cancel link / My Bookings) has no auth.uid();
      -- staff always do. SECURITY DEFINER does not change auth.uid().
      new.cancelled_by := case when auth.uid() is null then 'client' else 'staff' end;
    end if;
  end if;
  return new;
end;
$$;

drop trigger if exists trg_booking_cancelled_at on public.bookings;
create trigger trg_booking_cancelled_at
  before update on public.bookings
  for each row execute function public.set_booking_cancelled_at();

-- ---------- 2. Per-coach notification prefs + unread stamp ----------
alter table public.profiles add column if not exists notify_cancellations boolean not null default true;
alter table public.profiles add column if not exists notify_unassigned_cancellations boolean not null default true;
alter table public.profiles add column if not exists cancellations_seen_at timestamptz;

-- Staff may set these on their OWN row (RLS "staff edit own profile"
-- already scopes it to id = auth.uid(); the column grant allows the write).
grant update (notify_cancellations, notify_unassigned_cancellations, cancellations_seen_at)
  on public.profiles to authenticated;

-- ---------- 3. The panel's data, in one admin-safe read ----------
-- Staff already have SELECT on bookings/slots via RLS, but the panel needs
-- a specific shape (client cancellations only, last N days, with the slot's
-- CURRENT status so "reopened vs rebooked vs removed" is accurate). Doing
-- it as a function keeps the client-vs-staff filter server-side.
create or replace function public.get_recent_cancellations(
  p_days int default 14,
  p_coach_id uuid default null,
  p_only_open boolean default false
) returns json
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_result json;
begin
  if not public.is_staff() then
    raise exception 'Not authorized.';
  end if;
  if p_days is null or p_days < 1 or p_days > 90 then
    p_days := 14;
  end if;

  select coalesce(json_agg(row_to_json(t) order by t.cancelled_at desc), '[]'::json)
  into v_result
  from (
    select b.id,
           b.cancelled_at,
           b.student_name,
           b.first_name,
           b.email,
           b.phone,
           b.parent_name,
           s.id           as slot_id,
           s.starts_at,
           s.duration_min,
           s.status       as slot_status,
           s.coach_id,
           po.name        as pool_name,
           coalesce(pr.display_name, 'Unassigned') as coach,
           -- how far before the lesson they cancelled (null if after start)
           case when s.starts_at > b.cancelled_at
                then extract(epoch from (s.starts_at - b.cancelled_at))::bigint
                else null end as seconds_before
    from public.bookings b
    join public.slots s   on s.id = b.slot_id
    join public.pools po  on po.id = s.pool_id
    left join public.profiles pr on pr.id = s.coach_id
    where b.status = 'cancelled'
      and b.cancelled_by = 'client'          -- staff cancellations excluded
      and b.cancelled_at is not null
      and b.cancelled_at >= now() - make_interval(days => p_days)
      and (p_coach_id is null or s.coach_id = p_coach_id)
      and (not p_only_open or s.status = 'open')
  ) t;

  return json_build_object('cancellations', v_result);
end;
$$;

revoke all on function public.get_recent_cancellations(int, uuid, boolean) from public;
revoke execute on function public.get_recent_cancellations(int, uuid, boolean) from anon;
grant execute on function public.get_recent_cancellations(int, uuid, boolean) to authenticated;

-- ---------- 4. cancel_booking returns the booking id ----------
-- The page needs it to fire the staff alert right after a client cancels.
-- Behaviour is otherwise identical to migration_v4/v8; only the returned
-- JSON gains a field (older callers ignoring it keep working).
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

  return json_build_object(
    'cancelled', true,
    'starts_at', v_slot.starts_at,
    'booking_id', v_booking.id
  );
end;
$$;

revoke all on function public.cancel_booking(uuid) from public;
grant execute on function public.cancel_booking(uuid) to anon, authenticated;
