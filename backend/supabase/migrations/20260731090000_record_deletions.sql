-- ============================================================
-- Issue #148 / #132 — server-side deletion log (`record_deletions`).
--
-- WHAT THIS IS FOR
--
-- PR #146 replaced "a row is absent from the pushed snapshot, therefore the
-- user deleted it" with an explicit, durable tombstone. That fixed the
-- destructive direction (device A's stale push can no longer delete rows
-- device B added), but the tombstone was *local*: it tells the cloud "this
-- device deleted this row", it does not tell the other device. So after B
-- deleted a record and pushed, A's cached copy survived A's next merge and got
-- re-upserted — the deletion was silently undone.
--
-- The only client-only way to close that is "a row missing from a complete
-- cloud read must be dropped locally", which is the same absence inference
-- Issue #132 exists to remove, merely pointed at the user's own device (and a
-- read that returns nothing because of an RLS hiccup but still reaches EOF is
-- indistinguishable from "everything was deleted"). So the fact has to be
-- stored, not inferred: this table IS the deletion, in the same sense that a
-- row is the record.
--
-- ============================================================
-- WHY A TRIGGER AND NOT A CLIENT INSERT
--
-- The obvious shape is "the client inserts a tombstone, then issues the
-- DELETE". Two things make the trigger strictly better, and both are
-- correctness, not convenience:
--
--   1. ATOMICITY. A client-side pair has a window between the two requests. If
--      the DELETE lands and the tombstone insert does not, the row is gone from
--      the cloud with nothing recording why — and the *other* device, which
--      only ever learns about deletions from this table, keeps its copy and
--      re-upserts it. The trigger writes the tombstone inside the deleting
--      statement's own transaction: either both happen or neither does.
--
--   2. CASCADES. `exercises` and `exercise_sets` are `ON DELETE CASCADE` under
--      their parents. When A deletes a session, the cloud also destroys child
--      rows A never heard of — the ones B added concurrently. A client-side
--      insert can only tombstone the ids A knows about, so B would never be
--      told its own child row is gone, would keep it locally, and would
--      re-upsert an orphan (or fail the FK). The trigger fires once per row the
--      cascade actually destroys, so every device is told about exactly the
--      rows that actually died.
--
-- (2) is what makes the convergence rule uniform: **delete-wins, per row, on
-- both sides.** The cloud resolves "A deleted the session while B edited a
-- child of it" by cascading; the client resolves the same conflict by applying
-- the tombstones for the parent and every cascaded child. Same conflict, same
-- answer — which is exactly the inconsistency Issue #148's gap 3 is about
-- (local merge said update-wins, the cascade said delete-wins).
--
-- ============================================================
-- WHY CLIENTS CANNOT WRITE OR ERASE TOMBSTONES
--
-- RLS below grants `SELECT` and nothing else. There is no INSERT policy (the
-- trigger function is SECURITY DEFINER and runs as the owner), no UPDATE
-- policy and no DELETE policy. That is deliberate:
--
--   * a forged tombstone deletes data on every other device — it is the one
--     kind of row in this schema that is destructive by existing;
--   * an erasable tombstone resurrects a deleted record, which is the very bug
--     this table exists to prevent.
--
-- So "a tombstone exists" is equivalent to "the row really was deleted", and no
-- client can make either half untrue.
-- ============================================================

CREATE TABLE record_deletions (
  -- The deleted row's own id, in *cloud* id space. Not a surrogate key: the
  -- natural key is what the client matches against its cache, and making it the
  -- key is also what lets a retried DELETE be idempotent (ON CONFLICT below)
  -- without needing a separate uniqueness constraint.
  id uuid NOT NULL,
  -- No FK to auth.users, on purpose. The trigger fires during cascades, and
  -- deleting an account cascades into all five record tables *after* the
  -- auth.users row itself is gone — an FK here would make that insert fail and
  -- take account deletion down with it. Orphans are swept by
  -- purge_record_deletions() below, which checks auth.users explicitly.
  user_id uuid NOT NULL,
  -- Constrained rather than free text: the client dispatches on this value, so
  -- an unknown table name is a silent no-op on every device. The CHECK turns
  -- "someone added a sixth synced table and forgot the trigger" into a failure
  -- at migration time instead of a data-loss report months later.
  table_name text NOT NULL CHECK (table_name IN (
    'workout_sessions', 'exercises', 'exercise_sets',
    'running_workouts', 'custom_exercises'
  )),
  -- Server clock, always. The pull cursor is derived from values read back out
  -- of this column, so no device's clock skew can ever move another device's
  -- cursor past a deletion it has not seen.
  deleted_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (user_id, table_name, id)
);

ALTER TABLE record_deletions ENABLE ROW LEVEL SECURITY;

-- Read-only, own rows only. See the header: there is intentionally no INSERT /
-- UPDATE / DELETE policy.
CREATE POLICY "record_deletions_select_own" ON record_deletions
  FOR SELECT USING (user_id = auth.uid());

-- The pull is `user_id = auth.uid() AND table_name = $1 AND deleted_at >= $2`,
-- paged by keyset on id — served by the primary key. This index is for the
-- retention sweep, which is the only query that crosses users.
CREATE INDEX idx_record_deletions_deleted_at ON record_deletions(deleted_at);

COMMENT ON TABLE record_deletions IS
  'Server-side tombstones: one row per deleted record row, written by trigger (including cascades). The only channel by which one device learns that another deleted something. Clients may SELECT only.';

-- ============================================================
-- The trigger.
--
-- SECURITY DEFINER because there is no INSERT policy for `authenticated` — the
-- whole point is that only a real deletion can produce a tombstone.
-- `SET search_path = public, pg_temp` per this project's convention for
-- definer functions (see 20260708000013's SECURITY NOTE).
--
-- ON CONFLICT DO NOTHING keeps the *original* deleted_at when the same id is
-- somehow deleted twice (a retried delete-by-id against a row a concurrent
-- request already removed). Refreshing the timestamp would push the tombstone's
-- expiry forward on every retry, which is harmless, and would also re-deliver
-- it to devices that already applied it, which is wasted work — but the real
-- reason is that `deleted_at` is a fact about when the user deleted the record,
-- and facts do not get rewritten.
-- ============================================================
CREATE OR REPLACE FUNCTION public.record_deletion_tombstone()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
BEGIN
  INSERT INTO public.record_deletions (id, user_id, table_name)
  VALUES (OLD.id, OLD.user_id, TG_TABLE_NAME)
  ON CONFLICT (user_id, table_name, id) DO NOTHING;
  RETURN NULL;
END $$;

COMMENT ON FUNCTION public.record_deletion_tombstone() IS
  'AFTER DELETE trigger for the five synced record tables: records a tombstone in record_deletions, in the deleting transaction, including rows destroyed by ON DELETE CASCADE.';

REVOKE ALL ON FUNCTION public.record_deletion_tombstone() FROM PUBLIC;
REVOKE ALL ON FUNCTION public.record_deletion_tombstone() FROM anon;
REVOKE ALL ON FUNCTION public.record_deletion_tombstone() FROM authenticated;

CREATE TRIGGER workout_sessions_record_deletion
  AFTER DELETE ON workout_sessions
  FOR EACH ROW EXECUTE FUNCTION public.record_deletion_tombstone();

CREATE TRIGGER exercises_record_deletion
  AFTER DELETE ON exercises
  FOR EACH ROW EXECUTE FUNCTION public.record_deletion_tombstone();

CREATE TRIGGER exercise_sets_record_deletion
  AFTER DELETE ON exercise_sets
  FOR EACH ROW EXECUTE FUNCTION public.record_deletion_tombstone();

CREATE TRIGGER running_workouts_record_deletion
  AFTER DELETE ON running_workouts
  FOR EACH ROW EXECUTE FUNCTION public.record_deletion_tombstone();

CREATE TRIGGER custom_exercises_record_deletion
  AFTER DELETE ON custom_exercises
  FOR EACH ROW EXECUTE FUNCTION public.record_deletion_tombstone();

-- ============================================================
-- Retention: 180 days.
--
-- A tombstone's job is to reach every device that still holds the row. A device
-- that has been offline longer than the retention window can no longer be told,
-- so the window IS the supported offline period, and picking it is picking how
-- long a phone may sit in a drawer before its owner can see a record they
-- deleted elsewhere come back.
--
-- 180 days rather than 30: a row here is on the order of a hundred bytes (tuple
-- header, two uuids, a short text, a timestamp, plus its index entry) and the
-- table grows with the number of *deletions*, not with the number of records.
-- Even a user who deletes a hundred records every month accrues well under a
-- megabyte a year, so the storage argument for a short window does not exist
-- here, while the correctness argument for a long one is direct.
--
-- It is not unbounded because "unbounded" is not a retention policy: without a
-- sweep, an account that churns records grows a table nothing ever reads past
-- its first few days, and every client's first-sync pull pays for all of it.
--
-- Devices offline longer than this degrade in a documented, non-destructive
-- direction — see `CloudSyncCoordinator.loadRemoteRecordDeletions`, which
-- detects that this cache has been out of touch longer than the window and logs
-- it. Deliberately a log line and not a behaviour change: every available
-- "action" is the absence inference this whole protocol exists to remove,
-- pointed at the user's own device. So the failure mode is "a record the user
-- deleted on another device reappears and has to be deleted again", never "a
-- record is destroyed" — and the next deletion converges normally.
-- ============================================================
CREATE OR REPLACE FUNCTION public.purge_record_deletions(
  p_retain interval DEFAULT interval '180 days'
)
RETURNS int
LANGUAGE plpgsql
SET search_path = public, pg_temp
AS $$
DECLARE
  v_count int;
BEGIN
  DELETE FROM record_deletions
  WHERE deleted_at < now() - p_retain
     -- Account deletion cannot cascade into this table (no FK — see the column
     -- comment), so orphans are collected here instead. Immediate rather than
     -- age-based: once the account is gone the rows are pure residue, and they
     -- are the only thing in here that could outlive the data they describe.
     OR NOT EXISTS (
       SELECT 1 FROM auth.users u WHERE u.id = record_deletions.user_id
     );
  GET DIAGNOSTICS v_count = ROW_COUNT;
  RETURN v_count;
END $$;

COMMENT ON FUNCTION public.purge_record_deletions(interval) IS
  'Deletes tombstones older than p_retain (default 180 days) and any belonging to deleted accounts. Scheduled daily in 20260731090500_schedule_record_deletion_purge.sql.';

-- Mandatory per the SECURITY NOTE in
-- 20260708000013_phase2_generation_rpc_and_scheduling_extensions.sql: functions
-- created in this project's public schema pick up an EXECUTE grant for `anon`
-- by default, and `REVOKE ALL ... FROM PUBLIC` alone does not remove it.
-- Without these lines purge_record_deletions would be reachable as an
-- unauthenticated POST /rpc/purge_record_deletions — letting anyone erase every
-- tombstone in the project and resurrect every deleted record on every device.
REVOKE ALL ON FUNCTION public.purge_record_deletions(interval) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.purge_record_deletions(interval) FROM anon;
REVOKE ALL ON FUNCTION public.purge_record_deletions(interval) FROM authenticated;
GRANT EXECUTE ON FUNCTION public.purge_record_deletions(interval) TO service_role;
