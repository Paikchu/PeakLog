import { test } from 'node:test';
import assert from 'node:assert/strict';
import {
  PROMPT_VERSION,
  REPLAN_PROMPT_VERSION,
  REPLAN_SYSTEM_PROMPT,
  buildReplanUserMessage,
} from '../supabase/functions/_shared/prompt.mjs';

test('REPLAN_PROMPT_VERSION is distinct from the weekly PROMPT_VERSION', () => {
  assert.notEqual(REPLAN_PROMPT_VERSION, PROMPT_VERSION);
});

test('REPLAN_SYSTEM_PROMPT documents all three structured signals', () => {
  assert.ok(REPLAN_SYSTEM_PROMPT.includes('skip_today'));
  assert.ok(REPLAN_SYSTEM_PROMPT.includes('low_energy'));
  assert.ok(REPLAN_SYSTEM_PROMPT.includes('time_limited'));
});

test('buildReplanUserMessage embeds the context as JSON, including replan.targetDates', () => {
  const context = { weekStartDate: '2026-07-06', replan: { signal: 'time_limited', targetDates: ['2026-07-09'] } };
  const message = buildReplanUserMessage(context);
  assert.ok(message.includes('targetDates'));
  const jsonPart = message.split('\n').pop();
  assert.deepEqual(JSON.parse(jsonPart), context);
});
