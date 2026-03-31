import test from "node:test";
import assert from "node:assert/strict";
import { createChatSSEStream } from "../supabase/functions/chat-send-message/streaming.ts";

test("createChatSSEStream emits an initial event before the async producer yields data", async () => {
  const stream = createChatSSEStream(async ({ send }) => {
    await new Promise((resolve) => setTimeout(resolve, 50));
    send({ type: "text-delta", textDelta: "hello" });
  });

  const reader = stream.getReader();
  const decoder = new TextDecoder();

  const first = await reader.read();
  assert.equal(first.done, false, "Expected the stream to emit an initial chunk immediately");

  const firstChunk = decoder.decode(first.value);
  assert.match(firstChunk, /"type":"ready"/, `Expected initial chunk to be the ready event, got: ${firstChunk}`);

  const second = await reader.read();
  assert.equal(second.done, false, "Expected the stream to emit a follow-up chunk from the producer");

  const secondChunk = decoder.decode(second.value);
  assert.match(secondChunk, /"type":"text-delta"/, `Expected second chunk to contain a streamed text delta, got: ${secondChunk}`);
  assert.match(secondChunk, /"textDelta":"hello"/, `Expected second chunk to contain the streamed text body, got: ${secondChunk}`);
});
