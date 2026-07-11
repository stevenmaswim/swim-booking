-- ============================================================
-- Migration v8 — KSJ Swimming
-- Run AFTER migration_v7.sql in: Supabase Dashboard > SQL Editor.
-- Idempotent — safe to re-run.
--
-- PER-STUDENT OVERLAP RULE. Previously any two bookings with the same
-- EMAIL could not overlap in time — which wrongly blocked one parent
-- booking two different kids into simultaneous lessons (different
-- slots/coaches) and pushed families toward fake second emails.
--
--   * book_slots now takes p_slots jsonb:
--       [{"slot_id":"…","first_name":"…","last_name":"…"}, …]
--     replacing p_slot_ids/p_first_name/p_last_name — each lesson
--     carries its own student.
--   * Overlaps only conflict for the SAME student (case-insensitive
--     trimmed "first last"), both within the new set and against the
--     email's existing confirmed bookings. Different students under
--     one email may book simultaneous lessons freely.
--   * Everything else is unchanged: OTP/24h-token verification, atomic
--     all-or-nothing with id-ordered row locks, cap of 8 upcoming per
--     email, per-slot public "First L." display (now per student).
--   * The old signature is DROPPED — deploy the new book.html with
--     this migration (the jsonb call shape changed).
-- ============================================================

create or replace function public.book_slots(
  p_slots jsonb,
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
  v_email text := lower(trim(coalesce(p_email, '')));
  v_parent text := trim(coalesce(p_parent_name, ''));
  v_entries jsonb;          -- normalized: slot_id, first, last, student_key
  v_ids uuid[];
  v_n int;
  v_e jsonb;
  v_upcoming int;
  v_client_id uuid;
  v_otp public.booking_otps%rowtype;
  v_verified boolean := false;
  v_new_token text := null;
  v_booking public.bookings%rowtype;
  v_bad timestamptz;
  v_bad_student text;
  v_bookings jsonb := '[]'::jsonb;
  v_fmt text := 'Dy Mon FMDD, FMHH12:MI AM';
  v_first1 text;   -- first student of the checkout (for the client record)
  v_last1 text;
  r record;
begin
  -- ---- shared field validation ----
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

  -- ---- per-entry validation ----
  if p_slots is null or jsonb_typeof(p_slots) <> 'array' or jsonb_array_length(p_slots) = 0 then
    raise exception 'Please select at least one lesson time.';
  end if;
  if jsonb_array_length(p_slots) > 8 then
    raise exception 'You can book at most 8 lessons at a time.';
  end if;
  for v_e in select * from jsonb_array_elements(p_slots) loop
    if coalesce(v_e->>'slot_id', '') !~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' then
      raise exception 'One of the selected lessons is invalid — please refresh and try again.';
    end if;
    if length(trim(coalesce(v_e->>'first_name', ''))) < 1 then
      raise exception 'Please enter the student''s first name for every lesson.';
    end if;
    if length(trim(coalesce(v_e->>'last_name', ''))) < 1 then
      raise exception 'Please enter the student''s last name for every lesson.';
    end if;
  end loop;

  -- Normalize + dedupe by slot id (first occurrence wins). student_key is
  -- the case-insensitive trimmed identity used for the overlap rule.
  select jsonb_agg(jsonb_build_object(
           'slot_id', t.slot_id, 'first', t.fn, 'last', t.ln,
           'student_key', lower(t.fn || ' ' || t.ln)) order by t.ord),
         array_agg(t.slot_id order by t.ord)
  into v_entries, v_ids
  from (
    select distinct on ((e.val->>'slot_id'))
      (e.val->>'slot_id')::uuid as slot_id,
      trim(e.val->>'first_name') as fn,
      trim(e.val->>'last_name')  as ln,
      e.ord
    from jsonb_array_elements(p_slots) with ordinality as e(val, ord)
    order by (e.val->>'slot_id'), e.ord
  ) t;
  v_n := cardinality(v_ids);

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
      -- increment (PostgREST = one transaction per call). See v6.
      return json_build_object('error', 'Incorrect code — please try again.');
    end if;
    v_verified := true;

    v_new_token := replace(gen_random_uuid()::text, '-', '') ||
                   replace(gen_random_uuid()::text, '-', '');
    insert into public.booking_email_tokens (email, token_hash, expires_at)
    values (v_email, encode(extensions.digest(v_new_token, 'sha256'), 'hex'),
            now() + interval '24 hours');
    delete from public.booking_email_tokens where expires_at < now();
  end if;

  -- ---- cap: 8 upcoming confirmed bookings per email (incl. this set) ----
  select count(*) into v_upcoming
  from public.bookings b join public.slots s on s.id = b.slot_id
  where lower(b.email) = v_email
    and b.status = 'confirmed' and s.starts_at > now();
  if v_upcoming + v_n > 8 then
    raise exception 'This would exceed 8 upcoming bookings for this email (you have %). Please contact us to book more.', v_upcoming;
  end if;

  -- ---- lock ALL requested slots in id order (deadlock-free) ----
  perform 1 from public.slots where id = any(v_ids) order by id for update;

  select s.starts_at into v_bad from public.slots s
  where s.id = any(v_ids) and (s.status <> 'open' or s.starts_at <= now())
  order by s.starts_at limit 1;
  if found then
    raise exception 'The % lesson was just taken or has passed — nothing was booked. Please pick a different time.',
      to_char(v_bad at time zone p_tz, v_fmt);
  end if;
  if (select count(*) from public.slots where id = any(v_ids)) <> v_n then
    raise exception 'One of the selected lessons no longer exists — nothing was booked. Please refresh and try again.';
  end if;

  -- ---- overlap WITHIN the new set: only a conflict for the SAME student ----
  select s1.starts_at, e1.e->>'first' into v_bad, v_bad_student
  from jsonb_array_elements(v_entries) e1(e)
  join jsonb_array_elements(v_entries) e2(e)
    on (e1.e->>'slot_id') < (e2.e->>'slot_id')
   and e1.e->>'student_key' = e2.e->>'student_key'
  join public.slots s1 on s1.id = (e1.e->>'slot_id')::uuid
  join public.slots s2 on s2.id = (e2.e->>'slot_id')::uuid
  where s1.starts_at < s2.starts_at + make_interval(mins => s2.duration_min)
    and s2.starts_at < s1.starts_at + make_interval(mins => s1.duration_min)
  limit 1;
  if found then
    raise exception '% is selected for two lessons that overlap (around %) — pick different times, or edit the student names if these are different children.',
      v_bad_student, to_char(v_bad at time zone p_tz, v_fmt);
  end if;

  -- ---- overlap vs EXISTING confirmed bookings: same email AND same student ----
  select s.starts_at, e.e->>'first' into v_bad, v_bad_student
  from jsonb_array_elements(v_entries) e(e)
  join public.slots ns on ns.id = (e.e->>'slot_id')::uuid
  join public.bookings b
    on b.status = 'confirmed' and lower(b.email) = v_email
   and lower(trim(b.first_name) || ' ' || trim(b.last_name)) = e.e->>'student_key'
  join public.slots s on s.id = b.slot_id and s.id <> all(v_ids)
  where s.starts_at < ns.starts_at + make_interval(mins => ns.duration_min)
    and ns.starts_at < s.starts_at + make_interval(mins => s.duration_min)
  limit 1;
  if found then
    raise exception '% already has a lesson at %.',
      v_bad_student, to_char(v_bad at time zone p_tz, v_fmt);
  end if;

  -- ---- find-or-create the client (the family/payer, keyed by email).
  -- Multiple students under one client record is expected; the client's
  -- own name fields track the first student of this checkout (cosmetic —
  -- each booking stores its own student).
  select t.fn, t.ln into v_first1, v_last1 from (
    select e.e->>'first' as fn, e.e->>'last' as ln
    from jsonb_array_elements(v_entries) e(e)
    join public.slots s on s.id = (e.e->>'slot_id')::uuid
    order by s.starts_at limit 1
  ) t;
  insert into public.clients (name, first_name, last_name, parent_name, email, phone)
  values (v_first1 || ' ' || v_last1, v_first1, v_last1, v_parent, v_email, trim(p_phone))
  on conflict (email) do update
    set phone = excluded.phone,
        first_name = excluded.first_name,
        last_name = excluded.last_name,
        parent_name = excluded.parent_name,
        name = excluded.name
  returning id into v_client_id;

  -- ---- book every slot with ITS student ----
  for r in
    select (e.e->>'slot_id')::uuid as slot_id,
           e.e->>'first' as fn, e.e->>'last' as ln, s.starts_at
    from jsonb_array_elements(v_entries) e(e)
    join public.slots s on s.id = (e.e->>'slot_id')::uuid
    order by s.starts_at
  loop
    insert into public.bookings
      (slot_id, student_name, first_name, last_name, parent_name, email, phone, client_id)
    values
      (r.slot_id, r.fn || ' ' || r.ln, r.fn, r.ln, v_parent, v_email, trim(p_phone), v_client_id)
    returning * into v_booking;

    update public.slots
    set status = 'booked',
        booked_by_display = r.fn || ' ' || upper(left(r.ln, 1)) || '.'
    where id = r.slot_id;

    v_bookings := v_bookings || jsonb_build_object(
      'booking_id', v_booking.id,
      'cancel_token', v_booking.cancel_token,
      'starts_at', r.starts_at,
      'student', r.fn
    );
  end loop;

  return json_build_object(
    'bookings', v_bookings,
    'verify_token', v_new_token   -- null when a still-valid token was used
  );
end;
$$;

revoke all on function public.book_slots(jsonb, text, text, text, text, text, text) from public;
grant execute on function public.book_slots(jsonb, text, text, text, text, text, text) to anon, authenticated;

-- The old shape is gone — one booking path only (same reasoning as v6).
drop function if exists public.book_slots(uuid[], text, text, text, text, text, text, text, text);

-- ============================================================
-- edit_slot: same rule fix on the staff side. The v5 client-overlap
-- check was email-scoped, so staff couldn't move one kid's lesson onto
-- a sibling's time. Now it conflicts only for the SAME student.
-- (Everything else is unchanged from migration_v5.sql.)
-- ============================================================
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
    -- The same STUDENT double-booked? (v8: siblings on one email are fine)
    if exists (
      select 1 from public.bookings b join public.slots s on s.id = b.slot_id
      where lower(b.email) = lower(v_book.email) and b.status = 'confirmed' and s.id <> p_slot_id
        and lower(trim(b.first_name) || ' ' || trim(b.last_name))
            = lower(trim(v_book.first_name) || ' ' || trim(v_book.last_name))
        and s.starts_at < p_starts_at + make_interval(mins => p_duration_min)
        and p_starts_at < s.starts_at + make_interval(mins => s.duration_min)
    ) then
      raise exception 'This student already has another lesson that overlaps this time.';
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
