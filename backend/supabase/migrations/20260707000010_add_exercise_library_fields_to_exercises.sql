-- Preserve the library slug and load type on logged exercises so a
-- pull → push round-trip does not drop them.
-- Applied to fqyurmsuvtdafbnynurg on 2026-07-07 via MCP.
ALTER TABLE exercises
  ADD COLUMN IF NOT EXISTS exercise_id text,
  ADD COLUMN IF NOT EXISTS exercise_load_type varchar(16) NOT NULL DEFAULT 'unknown'
    CHECK (exercise_load_type IN ('bodyweight', 'weighted', 'unknown'));
