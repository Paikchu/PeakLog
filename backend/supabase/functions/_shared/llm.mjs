// LLM provider adapter. Deliberately has no dependency on Deno globals or env
// vars — the Edge Function reads config and passes plain arguments, so this
// module runs identically under `node --test` and the Deno edge runtime.
// Swapping providers later (e.g. adding Anthropic) means a new function with
// the same {rawText, parsed} return contract, not a change to callers.

const DEFAULT_TIMEOUT_MS = 60_000;

export class LlmError extends Error {
  constructor(message, { retryable = true, cause } = {}) {
    super(message);
    this.name = 'LlmError';
    this.retryable = retryable;
    if (cause) this.cause = cause;
  }
}

/**
 * @param {object} params
 * @param {string} params.systemPrompt
 * @param {string} params.userMessage
 * @param {string} params.apiKey
 * @param {string} [params.model]
 * @param {string} [params.baseUrl]
 * @param {typeof fetch} [params.fetchImpl] - injectable for tests
 * @param {number} [params.timeoutMs]
 * @returns {Promise<{rawText: string, parsed: object}>}
 */
export async function generateWithDeepSeek({
  systemPrompt,
  userMessage,
  apiKey,
  model = 'deepseek-chat',
  baseUrl = 'https://api.deepseek.com/chat/completions',
  fetchImpl = fetch,
  timeoutMs = DEFAULT_TIMEOUT_MS,
}) {
  if (!apiKey) throw new LlmError('missing DeepSeek API key', { retryable: false });

  const controller = new AbortController();
  const timeout = setTimeout(() => controller.abort(), timeoutMs);
  let response;
  try {
    response = await fetchImpl(baseUrl, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json', Authorization: `Bearer ${apiKey}` },
      body: JSON.stringify({
        model,
        messages: [
          { role: 'system', content: systemPrompt },
          { role: 'user', content: userMessage },
        ],
        response_format: { type: 'json_object' },
        temperature: 0.3,
      }),
      signal: controller.signal,
    });
  } catch (error) {
    throw new LlmError(`DeepSeek request failed: ${error.message}`, { retryable: true, cause: error });
  } finally {
    clearTimeout(timeout);
  }

  if (!response.ok) {
    const body = await safeText(response);
    throw new LlmError(`DeepSeek returned HTTP ${response.status}: ${body}`, { retryable: response.status >= 500 });
  }

  const payload = await response.json();
  const rawText = payload?.choices?.[0]?.message?.content;
  if (typeof rawText !== 'string') {
    throw new LlmError('DeepSeek response missing choices[0].message.content', { retryable: false });
  }

  let parsed;
  try {
    parsed = JSON.parse(rawText);
  } catch (error) {
    throw new LlmError(`DeepSeek response was not valid JSON: ${error.message}`, { retryable: false, cause: error });
  }

  return { rawText, parsed };
}

/**
 * Retries once (by default) on a retryable LlmError — transient network/5xx
 * failures only; a bad-JSON or missing-key failure is terminal and surfaces
 * immediately so the caller can move on to a repair attempt or fallback.
 */
export async function generateWithRetry(generateFn, args, { retries = 1 } = {}) {
  let lastError;
  for (let attempt = 0; attempt <= retries; attempt += 1) {
    try {
      return await generateFn(args);
    } catch (error) {
      lastError = error;
      if (!(error instanceof LlmError) || !error.retryable || attempt === retries) throw error;
    }
  }
  throw lastError;
}

async function safeText(response) {
  try {
    return await response.text();
  } catch {
    return '<unreadable body>';
  }
}
