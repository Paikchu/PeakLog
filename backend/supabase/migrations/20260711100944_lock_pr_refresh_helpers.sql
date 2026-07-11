REVOKE ALL ON FUNCTION refresh_exercise_prs_for_user(uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION refresh_exercise_prs_for_user(uuid) FROM anon;
REVOKE ALL ON FUNCTION refresh_exercise_prs_for_user(uuid) FROM authenticated;
GRANT EXECUTE ON FUNCTION refresh_exercise_prs_for_user(uuid) TO service_role;

REVOKE ALL ON FUNCTION recompute_user_stats_for_user(uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION recompute_user_stats_for_user(uuid) FROM anon;
REVOKE ALL ON FUNCTION recompute_user_stats_for_user(uuid) FROM authenticated;
GRANT EXECUTE ON FUNCTION recompute_user_stats_for_user(uuid) TO service_role;
