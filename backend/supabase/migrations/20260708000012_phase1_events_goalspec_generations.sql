-- ============================================================
-- Phase 1: structured goals, plan-edit event stream, generation
-- provenance. See docs/plans/2026-07-08-phase1-edit-events-goalspec-plan.md
-- Applied to fqyurmsuvtdafbnynurg on 2026-07-08 via MCP.
-- ============================================================

-- ============================================================
-- 1. user_goal_specs — one row per user
-- PK is user_id itself (not a synthetic id): the client always knows
-- its own user_id, so an upsert's conflict key is the PK directly.
-- This sidesteps both Phase 0 bugs (profiles has no INSERT policy;
-- user_preferences' unique key isn't its PK) at the schema level.
-- ============================================================
CREATE TABLE user_goal_specs (
  user_id uuid PRIMARY KEY REFERENCES auth.users(id) ON DELETE CASCADE,
  objective varchar(32) NOT NULL DEFAULT 'general'
    CHECK (objective IN ('muscle_gain', 'strength', 'fat_loss', 'endurance', 'general')),
  days_per_week int NOT NULL DEFAULT 3 CHECK (days_per_week BETWEEN 1 AND 7),
  session_minutes int NOT NULL DEFAULT 60 CHECK (session_minutes BETWEEN 15 AND 240),
  equipment text[] NOT NULL DEFAULT '{}',
  focus_areas text[] NOT NULL DEFAULT '{}',
  experience varchar(16) NOT NULL DEFAULT 'beginner'
    CHECK (experience IN ('beginner', 'intermediate', 'advanced')),
  note text,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);

COMMENT ON TABLE user_goal_specs IS
  'Structured training goal, one row per user. Server CHECKs are loose sanity bounds only — the client is the strict validator; tightening a CHECK beyond what the client enforces can permanently poison every future push for a user (see Phase 0 postmortem).';

ALTER TABLE user_goal_specs ENABLE ROW LEVEL SECURITY;
CREATE POLICY "user_goal_specs_all_own" ON user_goal_specs
  FOR ALL USING (user_id = auth.uid()) WITH CHECK (user_id = auth.uid());

CREATE TRIGGER user_goal_specs_updated_at
  BEFORE UPDATE ON user_goal_specs
  FOR EACH ROW EXECUTE FUNCTION moddatetime(updated_at);

GRANT ALL ON TABLE user_goal_specs TO service_role;

-- ============================================================
-- 2. plan_edit_events — append-only event stream
-- No FK to training_plans/_days: an event is a historical fact that
-- must survive the plan it references being archived or pruned.
-- Denormalized (exercise_name, plan_date, ...) so analysis never
-- needs to join a row that may no longer exist.
-- ============================================================
CREATE TABLE plan_edit_events (
  id uuid PRIMARY KEY,
  user_id uuid NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  plan_id uuid,
  plan_day_id uuid,
  plan_date date,
  event_type varchar(32) NOT NULL,
  exercise_name varchar(255),
  exercise_id text,
  payload jsonb NOT NULL DEFAULT '{}'::jsonb,
  source varchar(16) NOT NULL DEFAULT 'user'
    CHECK (source IN ('user', 'agent', 'system')),
  client_seq bigint NOT NULL,
  occurred_at timestamptz NOT NULL,
  created_at timestamptz NOT NULL DEFAULT now()
);

COMMENT ON TABLE plan_edit_events IS
  'Append-only. RLS intentionally grants only INSERT+SELECT — no UPDATE/DELETE policy exists, so history cannot be altered even by a buggy client. source must be "agent" for any Phase 2+ server-side plan mutation, or the learning signal is self-contaminated by conflating AI edits with user edits.';

ALTER TABLE plan_edit_events ENABLE ROW LEVEL SECURITY;
CREATE POLICY "plan_edit_events_insert_own" ON plan_edit_events
  FOR INSERT WITH CHECK (user_id = auth.uid());
CREATE POLICY "plan_edit_events_select_own" ON plan_edit_events
  FOR SELECT USING (user_id = auth.uid());

CREATE INDEX idx_plan_edit_events_user_time ON plan_edit_events(user_id, occurred_at DESC);
CREATE INDEX idx_plan_edit_events_plan ON plan_edit_events(plan_id);

GRANT SELECT, INSERT ON TABLE plan_edit_events TO service_role;

-- ============================================================
-- 3. plan_generations — generation provenance (schema only this
-- phase; the Phase 2 generation Edge Function is the only writer,
-- via service_role which bypasses RLS). No INSERT/UPDATE policy for
-- authenticated clients is intentional, not an oversight — the
-- mirror image of the profiles lesson from Phase 0.
-- ============================================================
CREATE TABLE plan_generations (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id uuid NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  plan_id uuid,
  engine varchar(16) NOT NULL DEFAULT 'llm',
  model_name varchar(64),
  prompt_version varchar(32),
  context_snapshot jsonb,
  raw_response jsonb,
  validator_verdicts jsonb,
  status varchar(16) NOT NULL DEFAULT 'draft'
    CHECK (status IN ('draft', 'active', 'superseded', 'failed')),
  error text,
  generated_at timestamptz NOT NULL DEFAULT now()
);

COMMENT ON TABLE plan_generations IS
  'Generation provenance. Client has SELECT only — no INSERT/UPDATE policy. Written exclusively by the Phase 2 server-side generation function via service_role.';

ALTER TABLE plan_generations ENABLE ROW LEVEL SECURITY;
CREATE POLICY "plan_generations_select_own" ON plan_generations
  FOR SELECT USING (user_id = auth.uid());

CREATE INDEX idx_plan_generations_user_time ON plan_generations(user_id, generated_at DESC);

GRANT ALL ON TABLE plan_generations TO service_role;
