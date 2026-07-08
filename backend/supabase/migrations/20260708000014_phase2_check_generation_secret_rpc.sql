-- check_generation_secret: lets the generate-weekly-plan Edge Function verify
-- an incoming request's x-generation-secret header against the Vault-stored
-- value, using the function's own auto-injected service-role client (no raw
-- Postgres driver, no manually-configured Edge Function secret needed).
--
-- SECURITY DEFINER + service_role-only, same pattern (and same anon-grant
-- pitfall already fixed once for install_generated_plan) as the rest of
-- Phase 2 — REVOKE explicitly from anon/authenticated/PUBLIC, plus an
-- in-function auth.role() check as defense in depth.
-- Applied to fqyurmsuvtdafbnynurg on 2026-07-08 via MCP.
CREATE OR REPLACE FUNCTION check_generation_secret(candidate text)
RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_expected text;
BEGIN
  IF auth.role() IS DISTINCT FROM 'service_role' THEN
    RAISE EXCEPTION 'check_generation_secret may only be called by service_role'
      USING ERRCODE = 'insufficient_privilege';
  END IF;

  SELECT decrypted_secret INTO v_expected FROM vault.decrypted_secrets WHERE name = 'generation_secret';
  RETURN v_expected IS NOT NULL AND candidate = v_expected;
END;
$$;

REVOKE ALL ON FUNCTION check_generation_secret(text) FROM PUBLIC;
REVOKE ALL ON FUNCTION check_generation_secret(text) FROM authenticated;
REVOKE ALL ON FUNCTION check_generation_secret(text) FROM anon;
GRANT EXECUTE ON FUNCTION check_generation_secret(text) TO service_role;

COMMENT ON FUNCTION check_generation_secret(text) IS
  'Verifies a candidate x-generation-secret header value against Vault. Called by generate-weekly-plan using its own auto-injected service-role client. service_role only.';
