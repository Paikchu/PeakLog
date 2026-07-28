-- Give profiles.timezone a real validity invariant, so every reader can stop
-- defending against malformed values individually.
--
-- WHY A FOURTH GUARD WOULD BE THE WRONG FIX
-- profiles.timezone is a free-form varchar(64) with no constraint
-- (20260318000001_schema.sql). Three separate layers have each had to work
-- around that independently:
--
--   1. _shared/generationWindow.mjs   -- Intl.DateTimeFormat throws RangeError
--   2. index.ts profile boundaries    -- so timezone.mjs's helpers throw too
--   3. install_generated_plan /       -- `now() AT TIME ZONE v_user_timezone`
--      replan_plan_days                  raises SQLSTATE 22023
--
-- Layers 1 and 2 are fixed in JavaScript. Layer 3 sits behind the RPC boundary
-- where no JavaScript guard can reach: both RPCs re-read profiles.timezone
-- themselves and only `coalesce(..., 'UTC')`, which handles NULL but not an
-- unrecognized name. Verified against this database:
--   select now() at time zone 'Asia/Shanghi'
--   -> ERROR 22023: time zone "Asia/Shanghi" not recognized
--
-- Post-JS-fix that failure mode is quieter but not gone, and arguably worse:
-- the hourly sweep now survives, weekly generation for the affected user runs
-- the full LLM pipeline, and only then does install_generated_plan reject the
-- write. No plan exists afterwards, so every remaining Sunday tick repeats the
-- same doomed (and billable) generation, and that user never receives a plan.
--
-- Rather than add a fourth guard inside each RPC, make the column trustworthy:
-- normalize on write, so present and future readers -- SQL and JavaScript
-- alike -- can rely on it. The JS guards stay as defense in depth.
--
-- WHY A TRIGGER AND NOT A CHECK CONSTRAINT
-- Postgres forbids subqueries in CHECK constraints, and validity can only be
-- decided by consulting pg_timezone_names / the `AT TIME ZONE` machinery,
-- neither of which is IMMUTABLE. A BEFORE trigger is the supported mechanism.
--
-- The validity test deliberately uses `now() AT TIME ZONE tz` itself rather
-- than a pg_timezone_names lookup, so this accepts exactly what the RPCs
-- accept -- including abbreviations that are valid for AT TIME ZONE but absent
-- from pg_timezone_names. Anything else becomes 'UTC', matching the fallback
-- already used by the Edge Function (resolveTimezone) and by the RPCs for NULL.

-- STABLE, not IMMUTABLE: what counts as a usable zone comes from the server's
-- tzdata, which can change across a Postgres upgrade. The probe is a fixed
-- timestamp rather than now() -- zone-name validity does not depend on the
-- instant, and a constant keeps this free of transaction-time semantics.
CREATE OR REPLACE FUNCTION public.resolve_timezone(p_timezone text)
RETURNS text
LANGUAGE plpgsql
STABLE
SET search_path = public
AS $$
DECLARE
  v_probe timestamptz;
BEGIN
  IF p_timezone IS NULL OR btrim(p_timezone) = '' THEN
    RETURN 'UTC';
  END IF;
  BEGIN
    v_probe := TIMESTAMP '2000-01-01 00:00:00' AT TIME ZONE p_timezone;
    RETURN p_timezone;
  EXCEPTION
    -- The expected failure for an unrecognized zone name, verified live:
    -- `now() at time zone 'Asia/Shanghi'` -> 22023 invalid_parameter_value.
    -- 22007 covers malformed input reaching the cast.
    WHEN invalid_parameter_value OR invalid_datetime_format THEN
      RETURN 'UTC';
    -- Anything else is not what this guard was written for. Still fall back
    -- rather than fail the profile write -- blocking a user's profile update
    -- over an unexpected error class is worse than running them on UTC -- but
    -- never let it disappear without a trace: once the trigger normalizes on
    -- write this function is the only line of defense, so a silently
    -- miscategorized error would propagate everywhere.
    WHEN OTHERS THEN
      RAISE WARNING 'resolve_timezone: unexpected % (%) probing timezone %, falling back to UTC',
        SQLSTATE, SQLERRM, p_timezone;
      RETURN 'UTC';
  END;
END $$;

COMMENT ON FUNCTION public.resolve_timezone(text) IS
  'Returns p_timezone when Postgres can actually use it as a time zone, otherwise ''UTC''. Mirrors resolveTimezone() in _shared/generationWindow.mjs so the SQL and JavaScript sides agree on what a usable timezone is.';

CREATE OR REPLACE FUNCTION public.normalize_profile_timezone()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER SET search_path = public
AS $$
BEGIN
  NEW.timezone := public.resolve_timezone(NEW.timezone);
  RETURN NEW;
END $$;

-- Permission lockdown, per the SECURITY NOTE in
-- 20260708000013_phase2_generation_rpc_and_scheduling_extensions.sql:28-39
-- (found live during Phase 2): functions created in this project's public
-- schema pick up an EXECUTE grant for `anon` by default, and `REVOKE ALL ...
-- FROM PUBLIC` alone does NOT remove it. Without this block
-- resolve_timezone(text) would be reachable as PostgREST /rpc/resolve_timezone
-- by any anon/authenticated client. It is a pure, side-effect-free string
-- check so the impact would be low, but it is an internal invariant helper,
-- not a public probe, and the convention exists precisely so this class of
-- oversight cannot recur.
REVOKE ALL ON FUNCTION public.resolve_timezone(text) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.resolve_timezone(text) FROM authenticated;
REVOKE ALL ON FUNCTION public.resolve_timezone(text) FROM anon;
GRANT EXECUTE ON FUNCTION public.resolve_timezone(text) TO service_role;

-- The trigger function returns `trigger`, so PostgREST cannot expose it via
-- /rpc at all; revoked anyway for consistency. Safe for ordinary client
-- profile writes: PostgreSQL checks EXECUTE on a trigger function at CREATE
-- TRIGGER time, not on each fire, and this one is SECURITY DEFINER. That
-- said, this migration has not been executed anywhere yet (no local Postgres
-- available), so "an authenticated client can still update its own
-- profiles.timezone" is a required smoke test when it is applied.
REVOKE ALL ON FUNCTION public.normalize_profile_timezone() FROM PUBLIC;
REVOKE ALL ON FUNCTION public.normalize_profile_timezone() FROM authenticated;
REVOKE ALL ON FUNCTION public.normalize_profile_timezone() FROM anon;

-- BEFORE INSERT fires unconditionally; BEFORE UPDATE only when the column is
-- actually written, so ordinary profile updates pay nothing.
DROP TRIGGER IF EXISTS profiles_normalize_timezone ON profiles;
CREATE TRIGGER profiles_normalize_timezone
  BEFORE INSERT OR UPDATE OF timezone ON profiles
  FOR EACH ROW
  EXECUTE FUNCTION public.normalize_profile_timezone();

-- One-time repair of any row that predates the trigger. Idempotent: a row that
-- is already valid resolves to itself and is excluded by the WHERE clause.
DO $$
DECLARE
  v_fixed integer;
BEGIN
  UPDATE profiles
  SET timezone = public.resolve_timezone(timezone)
  WHERE timezone IS DISTINCT FROM public.resolve_timezone(timezone);
  GET DIAGNOSTICS v_fixed = ROW_COUNT;
  RAISE NOTICE 'normalize_profile_timezone: repaired % pre-existing profile row(s)', v_fixed;
END $$;
