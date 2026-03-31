-- ============================================================
-- conversation_pending_actions
-- Stores a single unresolved clarification state per conversation.
-- ============================================================

CREATE TABLE conversation_pending_actions (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  conversation_id uuid NOT NULL REFERENCES conversations(id) ON DELETE CASCADE,
  user_id uuid NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  status varchar(32) NOT NULL DEFAULT 'pending',
  action_type varchar(32) NOT NULL,
  source_message_id uuid REFERENCES messages(id) ON DELETE SET NULL,
  payload_json jsonb NOT NULL DEFAULT '{}'::jsonb,
  created_at timestamptz NOT NULL DEFAULT now(),
  resolved_at timestamptz
);

ALTER TABLE conversation_pending_actions ENABLE ROW LEVEL SECURITY;
CREATE POLICY "conversation_pending_actions_select_own" ON conversation_pending_actions
  FOR SELECT USING (user_id = auth.uid());

CREATE INDEX idx_pending_actions_conversation_status
  ON conversation_pending_actions(conversation_id, status, created_at DESC);

CREATE UNIQUE INDEX idx_pending_actions_single_pending
  ON conversation_pending_actions(conversation_id)
  WHERE status = 'pending';

GRANT SELECT ON public.conversation_pending_actions TO authenticated;
GRANT ALL ON TABLE public.conversation_pending_actions TO service_role;
