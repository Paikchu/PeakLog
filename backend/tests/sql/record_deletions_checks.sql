-- Executable SQL checks for the Issue #148 server-side deletion log.
--
-- WHY THIS IS NOT A node --test FILE
-- backend/tests/recordDeletionsMigration.test.mjs asserts the migration *text*
-- contains the right constructs. That cannot tell you whether the trigger
-- actually fires for a row destroyed by ON DELETE CASCADE, or whether RLS
-- really hides another user's tombstones — both of which are the whole point,
-- and both of which only mean something against a real Postgres. This script
-- is that half, and it needs a live database, so it deliberately sits outside
-- `node --test`.
--
-- HOW TO RUN (requires Docker + the Supabase CLI):
--
--   cd backend/supabase && supabase start
--   psql "$(supabase status -o json | jq -r '.DB_URL')" \
--        -v ON_ERROR_STOP=1 -f ../tests/sql/record_deletions_checks.sql
--
-- Everything runs inside one transaction that ends in ROLLBACK, so it leaves no
-- rows behind. It prints one NOTICE per check and RAISEs on the first failure
-- (with ON_ERROR_STOP=1 that is a non-zero exit).

\set ON_ERROR_STOP on
BEGIN;

-- ------------------------------------------------------------------
-- Fixtures: two accounts, so the RLS check has someone to be isolated from.
-- ------------------------------------------------------------------
INSERT INTO auth.users (id) VALUES
  ('11111111-1111-4111-8111-111111111111'),
  ('22222222-2222-4222-8222-222222222222');

INSERT INTO workout_sessions (id, user_id, workout_date) VALUES
  ('aaaaaaaa-0000-4000-8000-000000000001', '11111111-1111-4111-8111-111111111111', current_date),
  ('aaaaaaaa-0000-4000-8000-000000000002', '22222222-2222-4222-8222-222222222222', current_date);

INSERT INTO exercises (id, session_id, user_id, name) VALUES
  ('bbbbbbbb-0000-4000-8000-000000000001', 'aaaaaaaa-0000-4000-8000-000000000001',
   '11111111-1111-4111-8111-111111111111', 'Bench');

INSERT INTO exercise_sets (id, exercise_id, user_id, set_index, reps) VALUES
  ('cccccccc-0000-4000-8000-000000000001', 'bbbbbbbb-0000-4000-8000-000000000001',
   '11111111-1111-4111-8111-111111111111', 1, 5);

INSERT INTO running_workouts (id, user_id, workout_date, duration_minutes, distance_km) VALUES
  ('dddddddd-0000-4000-8000-000000000001', '11111111-1111-4111-8111-111111111111', current_date, 30, 5);

INSERT INTO custom_exercises (id, user_id, name_en, name_zh, muscle_group) VALUES
  ('eeeeeeee-0000-4000-8000-000000000001', '11111111-1111-4111-8111-111111111111',
   'Zercher Squat', '泽奇深蹲', 'legs');

-- ------------------------------------------------------------------
-- 1. A leaf delete leaves exactly one tombstone, in the right table.
-- ------------------------------------------------------------------
DELETE FROM running_workouts WHERE id = 'dddddddd-0000-4000-8000-000000000001';
DELETE FROM custom_exercises WHERE id = 'eeeeeeee-0000-4000-8000-000000000001';

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM record_deletions
    WHERE id = 'dddddddd-0000-4000-8000-000000000001'
      AND table_name = 'running_workouts'
      AND user_id = '11111111-1111-4111-8111-111111111111'
  ) THEN
    RAISE EXCEPTION 'a deleted running_workout left no tombstone';
  END IF;
  IF NOT EXISTS (
    SELECT 1 FROM record_deletions
    WHERE id = 'eeeeeeee-0000-4000-8000-000000000001' AND table_name = 'custom_exercises'
  ) THEN
    RAISE EXCEPTION 'a deleted custom_exercise left no tombstone';
  END IF;
  RAISE NOTICE 'ok: leaf deletes are tombstoned';
END $$;

-- ------------------------------------------------------------------
-- 2. THE ONE THAT MATTERS: a cascade tombstones every row it destroys.
--
-- Deleting the session takes the exercise and its set with it via ON DELETE
-- CASCADE. Those child rows are exactly the ones the deleting *device* may
-- never have heard of (the other device added them), so if the cascade did not
-- tombstone them, the other device would keep its copies and re-upsert orphans
-- — and the client-side merge would be resolving the same conflict by a
-- different rule than the database. Issue #148 gap 3.
-- ------------------------------------------------------------------
DELETE FROM workout_sessions WHERE id = 'aaaaaaaa-0000-4000-8000-000000000001';

DO $$
DECLARE
  v_missing text;
BEGIN
  SELECT string_agg(expected.table_name || ':' || expected.id, ', ')
    INTO v_missing
  FROM (VALUES
    ('workout_sessions', 'aaaaaaaa-0000-4000-8000-000000000001'::uuid),
    ('exercises',        'bbbbbbbb-0000-4000-8000-000000000001'::uuid),
    ('exercise_sets',    'cccccccc-0000-4000-8000-000000000001'::uuid)
  ) AS expected(table_name, id)
  WHERE NOT EXISTS (
    SELECT 1 FROM record_deletions d
    WHERE d.table_name = expected.table_name AND d.id = expected.id
  );

  IF v_missing IS NOT NULL THEN
    RAISE EXCEPTION 'the cascade destroyed rows without tombstoning them: %', v_missing;
  END IF;
  RAISE NOTICE 'ok: ON DELETE CASCADE tombstones every row it destroys';
END $$;

-- ------------------------------------------------------------------
-- 3. Re-deleting keeps the original deleted_at.
--
-- The client's DELETE is delete-by-id and gets retried freely. If a retry
-- refreshed the timestamp, a tombstone could keep pushing its own expiry
-- forward and would be re-delivered to devices that already applied it.
-- ------------------------------------------------------------------
DO $$
DECLARE
  v_before timestamptz;
  v_after timestamptz;
BEGIN
  SELECT deleted_at INTO v_before FROM record_deletions
   WHERE id = 'dddddddd-0000-4000-8000-000000000001';

  -- The row is already gone, so this DELETE matches nothing and the trigger
  -- does not fire; insert-and-delete it again to exercise ON CONFLICT.
  INSERT INTO running_workouts (id, user_id, workout_date, duration_minutes, distance_km)
  VALUES ('dddddddd-0000-4000-8000-000000000001', '11111111-1111-4111-8111-111111111111',
          current_date, 30, 5);
  PERFORM pg_sleep(0.01);
  DELETE FROM running_workouts WHERE id = 'dddddddd-0000-4000-8000-000000000001';

  SELECT deleted_at INTO v_after FROM record_deletions
   WHERE id = 'dddddddd-0000-4000-8000-000000000001';

  IF v_after IS DISTINCT FROM v_before THEN
    RAISE EXCEPTION 're-deleting rewrote deleted_at: % -> %', v_before, v_after;
  END IF;
  IF (SELECT count(*) FROM record_deletions
       WHERE id = 'dddddddd-0000-4000-8000-000000000001') <> 1 THEN
    RAISE EXCEPTION 're-deleting produced a duplicate tombstone';
  END IF;
  RAISE NOTICE 'ok: a repeated delete is idempotent and keeps the original deleted_at';
END $$;

-- ------------------------------------------------------------------
-- 4. RLS: a user sees only their own tombstones, and cannot write any.
-- ------------------------------------------------------------------
DELETE FROM workout_sessions WHERE id = 'aaaaaaaa-0000-4000-8000-000000000002';

DO $$
DECLARE
  v_count int;
BEGIN
  SET LOCAL ROLE authenticated;
  PERFORM set_config('request.jwt.claims',
    '{"sub":"11111111-1111-4111-8111-111111111111","role":"authenticated"}', true);

  SELECT count(*) INTO v_count FROM record_deletions
   WHERE user_id = '22222222-2222-4222-8222-222222222222';
  IF v_count <> 0 THEN
    RAISE EXCEPTION 'RLS leaked % of another user''s tombstones', v_count;
  END IF;

  SELECT count(*) INTO v_count FROM record_deletions;
  IF v_count = 0 THEN
    RAISE EXCEPTION 'RLS hid the signed-in user''s own tombstones — the pull would read nothing';
  END IF;

  RAISE NOTICE 'ok: RLS shows own tombstones only (% visible)', v_count;
END $$;

DO $$
BEGIN
  SET LOCAL ROLE authenticated;
  PERFORM set_config('request.jwt.claims',
    '{"sub":"11111111-1111-4111-8111-111111111111","role":"authenticated"}', true);

  BEGIN
    INSERT INTO record_deletions (id, user_id, table_name)
    VALUES ('ffffffff-0000-4000-8000-000000000001',
            '11111111-1111-4111-8111-111111111111', 'workout_sessions');
    RAISE EXCEPTION 'a client forged a tombstone — that deletes data on every device the user owns';
  EXCEPTION WHEN insufficient_privilege THEN
    RAISE NOTICE 'ok: clients cannot insert tombstones';
  END;

  BEGIN
    DELETE FROM record_deletions WHERE id = 'aaaaaaaa-0000-4000-8000-000000000001';
    -- No DELETE policy means the statement affects zero rows rather than
    -- raising, so check the row is still there.
    IF NOT EXISTS (SELECT 1 FROM record_deletions
                    WHERE id = 'aaaaaaaa-0000-4000-8000-000000000001') THEN
      RAISE EXCEPTION 'a client erased a tombstone — that resurrects a deleted record';
    END IF;
    RAISE NOTICE 'ok: clients cannot erase tombstones';
  END;
END $$;

RESET ROLE;

-- ------------------------------------------------------------------
-- 5. Deleting an account does not fail, and the sweep collects its residue.
--
-- This is why there is no FK on user_id: the trigger fires during the cascade,
-- by which point the auth.users row is already gone, and an FK insert would
-- abort the whole account deletion.
-- ------------------------------------------------------------------
DO $$
DECLARE
  v_orphans int;
  v_purged int;
BEGIN
  DELETE FROM auth.users WHERE id = '22222222-2222-4222-8222-222222222222';

  SELECT count(*) INTO v_orphans FROM record_deletions
   WHERE user_id = '22222222-2222-4222-8222-222222222222';
  IF v_orphans = 0 THEN
    RAISE EXCEPTION 'fixture: the deleted account should have left tombstones to sweep';
  END IF;

  SELECT public.purge_record_deletions() INTO v_purged;
  IF EXISTS (SELECT 1 FROM record_deletions
              WHERE user_id = '22222222-2222-4222-8222-222222222222') THEN
    RAISE EXCEPTION 'the sweep left % tombstones belonging to a deleted account', v_orphans;
  END IF;
  IF NOT EXISTS (SELECT 1 FROM record_deletions
                  WHERE user_id = '11111111-1111-4111-8111-111111111111') THEN
    RAISE EXCEPTION 'the sweep took a live account''s fresh tombstones with it';
  END IF;

  RAISE NOTICE 'ok: account deletion succeeds and its residue is swept (% rows)', v_purged;
END $$;

-- ------------------------------------------------------------------
-- 6. Retention: only tombstones past the window go.
-- ------------------------------------------------------------------
DO $$
DECLARE
  v_purged int;
BEGIN
  UPDATE record_deletions
     SET deleted_at = now() - interval '181 days'
   WHERE id = 'cccccccc-0000-4000-8000-000000000001';

  SELECT public.purge_record_deletions() INTO v_purged;

  IF EXISTS (SELECT 1 FROM record_deletions WHERE id = 'cccccccc-0000-4000-8000-000000000001') THEN
    RAISE EXCEPTION 'a tombstone past the retention window survived the sweep';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM record_deletions WHERE id = 'bbbbbbbb-0000-4000-8000-000000000001') THEN
    RAISE EXCEPTION 'the sweep took a tombstone that is still inside the window';
  END IF;

  RAISE NOTICE 'ok: retention drops only what is past 180 days (% rows)', v_purged;
END $$;

ROLLBACK;
