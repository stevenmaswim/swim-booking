-- ============================================================
-- verify_v6.sql — post-migration verification for migration_v6.sql
-- Paste the WHOLE file into Supabase Dashboard > SQL Editor and run.
-- Everything happens inside one transaction and is ROLLED BACK at the
-- end — no test data survives. Read the NOTICE lines: every check
-- prints PASS or FAIL.
--
-- It simulates JWTs with set_config(), which exercises the same RLS
-- policies and SECURITY DEFINER gates the REST API hits. For a belt-
-- and-braces check with REAL tokens, also run verify_v6_api.mjs.
-- ============================================================
begin;

-- ---------- test fixtures (all rolled back) ----------
do $$
declare
  v_admin uuid := '11111111-1111-1111-1111-111111111111';
  v_coach uuid := '22222222-2222-2222-2222-222222222222';
  v_pool  uuid := '33333333-3333-3333-3333-333333333333';
begin
  insert into public.staff_emails (email) values
    ('vtest-admin@example.com'), ('vtest-coach@example.com')
  on conflict do nothing;

  -- Minimal auth users; the on_auth_user_created trigger builds profiles.
  begin
    insert into auth.users (instance_id, id, aud, role, email)
    values ('00000000-0000-0000-0000-000000000000', v_admin, 'authenticated', 'authenticated', 'vtest-admin@example.com'),
           ('00000000-0000-0000-0000-000000000000', v_coach, 'authenticated', 'authenticated', 'vtest-coach@example.com');
  exception when others then
    raise exception 'Could not create test users in auth.users (%). This Supabase project restricts direct auth writes — use verify_v6_api.mjs with real JWTs instead.', sqlerrm;
  end;
  update public.profiles set role = 'admin' where id = v_admin;

  insert into public.pools (id, name) values (v_pool, 'VTest Pool');

  -- Open slots tomorrow 10:00/11:00/12:00 + extras for cap/steal tests
  insert into public.slots (id, pool_id, coach_id, starts_at, duration_min, price, created_by)
  select ('44444444-4444-4444-4444-4444444400' || lpad(n::text, 2, '0'))::uuid,
         v_pool, v_coach,
         date_trunc('day', now()) + interval '1 day' + make_interval(hours => 9 + n),
         60, 50, v_coach
  from generate_series(1, 11) n;
  -- a cancelled future slot (reopen target) + a cancelled past slot
  insert into public.slots (id, pool_id, coach_id, starts_at, duration_min, price, status, created_by) values
    ('44444444-4444-4444-4444-444444440091', v_pool, v_coach, now() + interval '3 days', 60, 50, 'cancelled', v_coach),
    ('44444444-4444-4444-4444-444444440092', v_pool, v_coach, now() - interval '3 days', 60, 50, 'cancelled', v_coach),
  -- a slot owned by the admin (for coach-cannot-touch tests)
    ('44444444-4444-4444-4444-444444440093', v_pool, v_admin, now() + interval '4 days', 60, 50, 'open', v_admin);

  -- OTP for the test client: code 123456
  insert into public.booking_otps (email, code_hash, expires_at)
  values ('vtest-client@example.com', encode(extensions.digest('123456', 'sha256'), 'hex'), now() + interval '10 minutes');
  raise notice 'fixtures ready';
end $$;

create temporary table vstate (k text primary key, v text) on commit drop;

-- helper claims
--   admin: {"sub":"...1111","email":"vtest-admin@example.com","role":"authenticated"}
--   coach: {"sub":"...2222","email":"vtest-coach@example.com","role":"authenticated"}

-- ============================================================
-- A. book_slots behaviour (verification, lockout, atomicity, cap)
-- ============================================================
do $$
declare r json; n int;
begin
  -- A1: no code, no token → must refuse
  begin
    r := public.book_slots(array['44444444-4444-4444-4444-444444440001']::uuid[],
         'Kid', 'One', 'Parent One', 'vtest-client@example.com', '2045550000');
    raise notice 'FAIL A1: booked without any email verification';
  exception when others then
    if sqlerrm like '%verify your email%' then raise notice 'PASS A1: verification required';
    else raise notice 'FAIL A1: unexpected error: %', sqlerrm; end if;
  end;

  -- A2: five wrong codes → each returns {error}, attempts persist…
  for n in 1..5 loop
    r := public.book_slots(array['44444444-4444-4444-4444-444444440001']::uuid[],
         'Kid', 'One', 'Parent One', 'vtest-client@example.com', '2045550000', '000000');
    if r->>'error' is null then raise notice 'FAIL A2.%: wrong code accepted', n; end if;
  end loop;
  select attempts into n from public.booking_otps where email = 'vtest-client@example.com'
  order by created_at desc limit 1;
  if n = 5 then raise notice 'PASS A2: 5 wrong codes recorded (attempts=5)';
  else raise notice 'FAIL A2: attempts=% (expected 5 — increments must persist!)', n; end if;

  -- A3: …and now even the CORRECT code is locked out
  begin
    r := public.book_slots(array['44444444-4444-4444-4444-444444440001']::uuid[],
         'Kid', 'One', 'Parent One', 'vtest-client@example.com', '2045550000', '123456');
    raise notice 'FAIL A3: locked-out code still worked';
  exception when others then
    if sqlerrm like '%Too many attempts%' then raise notice 'PASS A3: wrong OTP 5x locks out';
    else raise notice 'FAIL A3: unexpected error: %', sqlerrm; end if;
  end;
end $$;

do $$
declare r json; n int; tok text;
begin
  -- fresh code after lockout (created_at nudged forward: now() is frozen
  -- inside a transaction, and book_slots picks the NEWEST row)
  insert into public.booking_otps (email, code_hash, expires_at, created_at)
  values ('vtest-client@example.com', encode(extensions.digest('654321', 'sha256'), 'hex'),
          now() + interval '10 minutes', now() + interval '1 second');

  -- A4: book 3 slots atomically with the correct code
  r := public.book_slots(array['44444444-4444-4444-4444-444444440001',
                               '44444444-4444-4444-4444-444444440002',
                               '44444444-4444-4444-4444-444444440003']::uuid[],
       'Kid', 'One', 'Parent One', 'vtest-client@example.com', '2045550000', '654321');
  if json_array_length(r->'bookings') = 3 and r->>'verify_token' is not null then
    raise notice 'PASS A4: 3 slots booked in one call, 24h token issued';
  else
    raise notice 'FAIL A4: %', r::text;
  end if;
  insert into vstate values ('token', r->>'verify_token');

  -- A5: steal test — one of the next two slots gets booked mid-flow
  update public.slots set status = 'booked' where id = '44444444-4444-4444-4444-444444440005';
  begin
    r := public.book_slots(array['44444444-4444-4444-4444-444444440004',
                                 '44444444-4444-4444-4444-444444440005']::uuid[],
         'Kid', 'One', 'Parent One', 'vtest-client@example.com', '2045550000',
         null, (select v from vstate where k = 'token'));
    raise notice 'FAIL A5: booked through a stolen slot';
  exception when others then
    if sqlerrm like '%was just taken%' then raise notice 'PASS A5: steal detected and named: %', sqlerrm;
    else raise notice 'FAIL A5: unexpected error: %', sqlerrm; end if;
  end;
  select count(*) into n from public.bookings
  where slot_id in ('44444444-4444-4444-4444-444444440004', '44444444-4444-4444-4444-444444440005');
  if n = 0 then raise notice 'PASS A5b: steal booked ZERO of the set';
  else raise notice 'FAIL A5b: % bookings leaked through', n; end if;

  -- A6: token reuse (no code) books without re-verification
  r := public.book_slots(array['44444444-4444-4444-4444-444444440006']::uuid[],
       'Kid', 'One', 'Parent One', 'vtest-client@example.com', '2045550000',
       null, (select v from vstate where k = 'token'));
  if json_array_length(r->'bookings') = 1 and r->>'verify_token' is null then
    raise notice 'PASS A6: 24h token skips the code';
  else raise notice 'FAIL A6: %', r::text; end if;

  -- A7: cap of 8 upcoming — 4 booked so far, try 5 more
  begin
    r := public.book_slots(array['44444444-4444-4444-4444-444444440007',
                                 '44444444-4444-4444-4444-444444440008',
                                 '44444444-4444-4444-4444-444444440009',
                                 '44444444-4444-4444-4444-444444440010',
                                 '44444444-4444-4444-4444-444444440011']::uuid[],
         'Kid', 'One', 'Parent One', 'vtest-client@example.com', '2045550000',
         null, (select v from vstate where k = 'token'));
    raise notice 'FAIL A7: exceeded the 8-upcoming cap (got 9)';
  exception when others then
    if sqlerrm like '%8 upcoming bookings%' then raise notice 'PASS A7: cap of 8 enforced';
    else raise notice 'FAIL A7: unexpected error: %', sqlerrm; end if;
  end;

  -- A8: overlap within the requested set is rejected
  update public.slots set starts_at = (select starts_at from public.slots where id = '44444444-4444-4444-4444-444444440007')
  where id = '44444444-4444-4444-4444-444444440008';
  begin
    r := public.book_slots(array['44444444-4444-4444-4444-444444440007',
                                 '44444444-4444-4444-4444-444444440008']::uuid[],
         'Kid', 'One', 'Parent One', 'vtest-client@example.com', '2045550000',
         null, (select v from vstate where k = 'token'));
    raise notice 'FAIL A8: overlapping pair booked';
  exception when others then
    if sqlerrm like '%overlap%' then raise notice 'PASS A8: in-set overlap rejected';
    else raise notice 'FAIL A8: unexpected error: %', sqlerrm; end if;
  end;
end $$;

-- ============================================================
-- B. cancelled_at trigger + late-cancel data
-- ============================================================
do $$
declare b record;
begin
  update public.bookings set status = 'cancelled'
  where slot_id = '44444444-4444-4444-4444-444444440001';
  select bo.cancelled_at, s.starts_at into b
  from public.bookings bo join public.slots s on s.id = bo.slot_id
  where bo.slot_id = '44444444-4444-4444-4444-444444440001';
  if b.cancelled_at is not null and b.starts_at - b.cancelled_at < interval '24 hours' then
    raise notice 'PASS B1: cancelled_at auto-set; this one is late (<24h before start)';
  else
    raise notice 'FAIL B1: cancelled_at=% starts=%', b.cancelled_at, b.starts_at;
  end if;
  -- booked_by_display cleared when the slot leaves ''booked''
  update public.slots set status = 'open' where id = '44444444-4444-4444-4444-444444440001';
  if (select booked_by_display from public.slots where id = '44444444-4444-4444-4444-444444440001') is null then
    raise notice 'PASS B2: booked_by_display cleared on reopen';
  else raise notice 'FAIL B2: stale booked_by_display survived reopen'; end if;
end $$;

-- ============================================================
-- C. COACH JWT: everything admin-only must refuse
-- ============================================================
select set_config('request.jwt.claims',
  '{"sub":"22222222-2222-2222-2222-222222222222","email":"vtest-coach@example.com","role":"authenticated"}', true);

do $$
declare r json; n int;
begin
  if public.is_staff() and not public.is_admin() then
    raise notice 'PASS C0: coach claims recognised (staff, not admin)';
  else raise notice 'FAIL C0: is_staff/is_admin wrong for coach'; end if;

  begin
    r := public.admin_update_profile('22222222-2222-2222-2222-222222222222', 'X', '', true, 'admin');
    raise notice 'FAIL C1: coach promoted THEMSELVES via admin_update_profile';
  exception when others then
    if sqlerrm like '%Only admins%' then raise notice 'PASS C1: coach cannot call profile management';
    else raise notice 'FAIL C1: unexpected: %', sqlerrm; end if;
  end;

  begin
    r := public.get_revenue_grid(now() - interval '7 days', now() + interval '7 days');
    raise notice 'FAIL C2: coach read the revenue grid';
  exception when others then
    if sqlerrm like '%Only admins%' then raise notice 'PASS C2: coach cannot call revenue grid';
    else raise notice 'FAIL C2: unexpected: %', sqlerrm; end if;
  end;

  begin
    r := public.reopen_slot('44444444-4444-4444-4444-444444440091');
    raise notice 'FAIL C3: coach reopened a slot';
  exception when others then
    if sqlerrm like '%Only admins%' then raise notice 'PASS C3: coach cannot call reopen';
    else raise notice 'FAIL C3: unexpected: %', sqlerrm; end if;
  end;

  begin
    r := public.edit_slot('44444444-4444-4444-4444-444444440093',
         now() + interval '5 days', 60, '33333333-3333-3333-3333-333333333333',
         '22222222-2222-2222-2222-222222222222', 50);
    raise notice 'FAIL C4: coach edited the ADMIN''s slot';
  exception when others then
    if sqlerrm like '%own slots%' then raise notice 'PASS C4: coach cannot edit another coach''s slot';
    else raise notice 'FAIL C4: unexpected: %', sqlerrm; end if;
  end;
end $$;

-- RLS checks need the real API role too (definer functions above don't).
set local role authenticated;
do $$
declare n int;
begin
  -- C5: publishing under another coach's name is blocked by RLS
  begin
    insert into public.slots (pool_id, coach_id, starts_at, duration_min, price, created_by)
    values ('33333333-3333-3333-3333-333333333333', '11111111-1111-1111-1111-111111111111',
            now() + interval '6 days', 60, 50, '22222222-2222-2222-2222-222222222222');
    raise notice 'FAIL C5: coach published a slot under the admin''s name';
  exception when others then
    raise notice 'PASS C5: coach cannot publish for another coach (%)', sqlerrm;
  end;

  -- C6: publishing under their OWN name works
  begin
    insert into public.slots (pool_id, coach_id, starts_at, duration_min, price, created_by)
    values ('33333333-3333-3333-3333-333333333333', '22222222-2222-2222-2222-222222222222',
            now() + interval '6 days', 60, 50, '22222222-2222-2222-2222-222222222222');
    raise notice 'PASS C6: coach publishes their own slots';
  exception when others then
    raise notice 'FAIL C6: own-slot publish blocked: %', sqlerrm;
  end;

  -- C7: cancelling the admin's slot silently updates 0 rows
  with u as (update public.slots set status = 'cancelled'
             where id = '44444444-4444-4444-4444-444444440093' returning 1)
  select count(*) into n from u;
  if n = 0 then raise notice 'PASS C7: coach cannot cancel another coach''s slot (0 rows)';
  else raise notice 'FAIL C7: coach cancelled the admin''s slot'; end if;

  -- C8: role column has no API write grant at all
  begin
    update public.profiles set role = 'admin' where id = '22222222-2222-2222-2222-222222222222';
    raise notice 'FAIL C8: coach wrote profiles.role directly';
  exception when insufficient_privilege then
    raise notice 'PASS C8: profiles.role not writable via the API';
  when others then
    raise notice 'FAIL C8: unexpected: %', sqlerrm;
  end;
end $$;
reset role;

-- ============================================================
-- D. ANON role: admin RPCs are not even executable
-- ============================================================
select set_config('request.jwt.claims', '{"role":"anon"}', true);
set local role anon;
do $$
begin
  begin
    perform public.get_revenue_grid(now() - interval '7 days', now());
    raise notice 'FAIL D1: anon executed get_revenue_grid';
  exception when insufficient_privilege then
    raise notice 'PASS D1: anon lacks EXECUTE on get_revenue_grid';
  when others then raise notice 'FAIL D1: unexpected: %', sqlerrm;
  end;
  begin
    perform public.reopen_slot('44444444-4444-4444-4444-444444440091');
    raise notice 'FAIL D2: anon executed reopen_slot';
  exception when insufficient_privilege then
    raise notice 'PASS D2: anon lacks EXECUTE on reopen_slot';
  when others then raise notice 'FAIL D2: unexpected: %', sqlerrm;
  end;
  begin
    perform public.admin_update_profile('22222222-2222-2222-2222-222222222222', 'X', '', true, 'admin');
    raise notice 'FAIL D3: anon executed admin_update_profile';
  exception when insufficient_privilege then
    raise notice 'PASS D3: anon lacks EXECUTE on admin_update_profile';
  when others then raise notice 'FAIL D3: unexpected: %', sqlerrm;
  end;
end $$;
reset role;

-- ============================================================
-- E. ADMIN JWT: full control + last-admin guard
-- ============================================================
select set_config('request.jwt.claims',
  '{"sub":"11111111-1111-1111-1111-111111111111","email":"vtest-admin@example.com","role":"authenticated"}', true);

do $$
declare r json; v numeric;
begin
  if not public.is_admin() then raise notice 'FAIL E0: admin claims not recognised'; return; end if;

  -- E1: revenue grid includes the 3 still-confirmed test lessons (3 × $50;
  -- the 4th was cancelled in section B). Real bookings may add to the total.
  r := public.get_revenue_grid(now(), now() + interval '7 days');
  select coalesce(sum((c->>'revenue')::numeric), 0) into v
  from json_array_elements(r->'cells') c;
  if v >= 150 then raise notice 'PASS E1: revenue grid readable by admin (≥ $150 incl. test lessons: $%)', v;
  else raise notice 'FAIL E1: grid total $% (expected at least the 3 × $50 test bookings)', v; end if;

  -- E2: edit another coach's profile + promote/demote round trip
  r := public.admin_update_profile('22222222-2222-2222-2222-222222222222', 'VTest Coach Renamed', 'new bio', false, 'admin');
  if (select role from public.profiles where id = '22222222-2222-2222-2222-222222222222') = 'admin'
     and (select display_name from public.profiles where id = '22222222-2222-2222-2222-222222222222') = 'VTest Coach Renamed' then
    raise notice 'PASS E2: admin edited another profile incl. promotion';
  else raise notice 'FAIL E2: profile not updated'; end if;
  r := public.admin_update_profile('22222222-2222-2222-2222-222222222222', 'VTest Coach', 'bio', true, 'coach');

  -- E3: last-admin guard — demote every other admin (rolled back later!),
  -- then self-demotion must refuse.
  update public.profiles set role = 'coach' where role = 'admin' and id <> '11111111-1111-1111-1111-111111111111';
  begin
    r := public.admin_update_profile('11111111-1111-1111-1111-111111111111', 'VTest Admin', '', true, 'coach');
    raise notice 'FAIL E3: the LAST admin demoted themselves';
  exception when others then
    if sqlerrm like '%last admin%' then raise notice 'PASS E3: last-admin demotion blocked';
    else raise notice 'FAIL E3: unexpected: %', sqlerrm; end if;
  end;

  -- E4: reopen a future cancelled slot; refuse a past one
  r := public.reopen_slot('44444444-4444-4444-4444-444444440091');
  if (select status from public.slots where id = '44444444-4444-4444-4444-444444440091') = 'open' then
    raise notice 'PASS E4: admin reopened a future cancelled slot';
  else raise notice 'FAIL E4: slot not reopened'; end if;
  begin
    r := public.reopen_slot('44444444-4444-4444-4444-444444440092');
    raise notice 'FAIL E5: reopened a PAST slot';
  exception when others then
    if sqlerrm like '%in the past%' then raise notice 'PASS E5: past slots cannot be reopened';
    else raise notice 'FAIL E5: unexpected: %', sqlerrm; end if;
  end;

  -- E6: admin edits the coach's slot via edit_slot
  r := public.edit_slot('44444444-4444-4444-4444-444444440002',
       now() + interval '2 days', 45, '33333333-3333-3333-3333-333333333333',
       '22222222-2222-2222-2222-222222222222', 60);
  if (r->>'ok')::boolean then raise notice 'PASS E6: admin edited a coach''s slot';
  else raise notice 'FAIL E6: %', r::text; end if;
end $$;

-- E7: admin publishes a slot for someone else (RLS, as authenticated)
set local role authenticated;
do $$
begin
  begin
    insert into public.slots (pool_id, coach_id, starts_at, duration_min, price, created_by)
    values ('33333333-3333-3333-3333-333333333333', '22222222-2222-2222-2222-222222222222',
            now() + interval '8 days', 60, 50, '11111111-1111-1111-1111-111111111111');
    raise notice 'PASS E7: admin publishes slots for any coach';
  exception when others then
    raise notice 'FAIL E7: admin blocked from publishing for a coach: %', sqlerrm;
  end;
end $$;
reset role;

rollback;
-- All test users, slots, bookings, tokens and role changes are gone.
select 'verify_v6 finished — check the NOTICE output above; everything was rolled back' as done;
