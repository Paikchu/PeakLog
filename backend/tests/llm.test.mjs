import { test } from 'node:test';
import assert from 'node:assert/strict';
import { generateWithDeepSeek, generateWithRetry, LlmError } from '../supabase/functions/_shared/llm.mjs';

function jsonResponse(status, body) {
  return {
    ok: status >= 200 && status < 300,
    status,
    json: async () => body,
    text: async () => JSON.stringify(body),
  };
}

test('generateWithDeepSeek: missing API key fails fast, not retryable', async () => {
  await assert.rejects(
    () => generateWithDeepSeek({ systemPrompt: 's', userMessage: 'u', apiKey: undefined }),
    (error) => {
      assert.ok(error instanceof LlmError);
      assert.equal(error.retryable, false);
      return true;
    }
  );
});

test('generateWithDeepSeek: happy path parses choices[0].message.content as JSON', async () => {
  const fetchImpl = async (url, init) => {
    assert.equal(url, 'https://api.deepseek.com/chat/completions');
    const body = JSON.parse(init.body);
    assert.equal(body.model, 'deepseek-chat');
    assert.equal(body.response_format.type, 'json_object');
    assert.equal(init.headers.Authorization, 'Bearer test-key');
    return jsonResponse(200, { choices: [{ message: { content: '{"days": []}' } }] });
  };
  const result = await generateWithDeepSeek({ systemPrompt: 's', userMessage: 'u', apiKey: 'test-key', fetchImpl });
  assert.equal(result.rawText, '{"days": []}');
  assert.deepEqual(result.parsed, { days: [] });
});

test('generateWithDeepSeek: non-2xx response is a retryable error for 5xx', async () => {
  const fetchImpl = async () => jsonResponse(503, { error: 'overloaded' });
  await assert.rejects(
    () => generateWithDeepSeek({ systemPrompt: 's', userMessage: 'u', apiKey: 'k', fetchImpl }),
    (error) => {
      assert.ok(error instanceof LlmError);
      assert.equal(error.retryable, true);
      return true;
    }
  );
});

test('generateWithDeepSeek: 4xx response is not retryable', async () => {
  const fetchImpl = async () => jsonResponse(401, { error: 'bad key' });
  await assert.rejects(
    () => generateWithDeepSeek({ systemPrompt: 's', userMessage: 'u', apiKey: 'k', fetchImpl }),
    (error) => {
      assert.equal(error.retryable, false);
      return true;
    }
  );
});

test('generateWithDeepSeek: malformed JSON content is terminal, not retryable', async () => {
  const fetchImpl = async () => jsonResponse(200, { choices: [{ message: { content: 'not json {' } }] });
  await assert.rejects(
    () => generateWithDeepSeek({ systemPrompt: 's', userMessage: 'u', apiKey: 'k', fetchImpl }),
    (error) => {
      assert.equal(error.retryable, false);
      return true;
    }
  );
});

test('generateWithDeepSeek: a network-level throw is wrapped as retryable', async () => {
  const fetchImpl = async () => { throw new Error('DNS failure'); };
  await assert.rejects(
    () => generateWithDeepSeek({ systemPrompt: 's', userMessage: 'u', apiKey: 'k', fetchImpl }),
    (error) => {
      assert.ok(error instanceof LlmError);
      assert.equal(error.retryable, true);
      return true;
    }
  );
});

test('generateWithRetry: retries once on a retryable failure, then succeeds', async () => {
  let calls = 0;
  const generateFn = async () => {
    calls += 1;
    if (calls === 1) throw new LlmError('transient', { retryable: true });
    return { rawText: 'ok', parsed: {} };
  };
  const result = await generateWithRetry(generateFn, {});
  assert.equal(calls, 2);
  assert.deepEqual(result, { rawText: 'ok', parsed: {} });
});

test('generateWithRetry: does not retry a non-retryable error', async () => {
  let calls = 0;
  const generateFn = async () => {
    calls += 1;
    throw new LlmError('terminal', { retryable: false });
  };
  await assert.rejects(() => generateWithRetry(generateFn, {}));
  assert.equal(calls, 1, 'a terminal error must not be retried');
});

test('generateWithRetry: exhausts the retry budget and throws the last error', async () => {
  let calls = 0;
  const generateFn = async () => {
    calls += 1;
    throw new LlmError('always fails', { retryable: true });
  };
  await assert.rejects(() => generateWithRetry(generateFn, {}, { retries: 1 }));
  assert.equal(calls, 2, 'one initial attempt plus one retry');
});
