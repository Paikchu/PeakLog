import { test } from 'node:test';
import assert from 'node:assert/strict';
import {
  PROMPT_VERSION,
  REPLAN_PROMPT_VERSION,
  SYSTEM_PROMPT,
  REPLAN_SYSTEM_PROMPT,
  buildReplanUserMessage,
} from '../supabase/functions/_shared/prompt.mjs';

test('weekly and replan prompts expose the cardio plan item contract', () => {
  for (const prompt of [SYSTEM_PROMPT, REPLAN_SYSTEM_PROMPT]) {
    assert.ok(prompt.includes('"itemType": "strength" | "cardio"'));
    assert.ok(prompt.includes('"cardioActivityType": "running" | "cycling" | "elliptical" | "stair_climber" | null'));
    assert.ok(prompt.includes('"targetDurationMinutes": integer|null'));
    assert.ok(prompt.includes('elliptical and stair_climber items must have targetDistanceKm null'));
  }
  assert.notEqual(PROMPT_VERSION, 'v1');
  assert.notEqual(REPLAN_PROMPT_VERSION, 'replan-v1');
});

test('weekly prompt keeps cardio subordinate to recovery and training-day limits', () => {
  assert.ok(SYSTEM_PROMPT.includes('1-2 low-to-moderate cardio items'));
  assert.ok(SYSTEM_PROMPT.includes('must not increase the number of training days'));
  assert.ok(SYSTEM_PROMPT.includes('must not displace recovery'));
});

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
