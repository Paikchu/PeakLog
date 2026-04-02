import test from "node:test";
import assert from "node:assert/strict";
import fs from "node:fs";

const schemaSource = fs.readFileSync(
  "/Users/max/Developer/IOS/PeakLog/backend/supabase/functions/chat-send-message/schema.ts",
  "utf8",
);

const agentSource = fs.readFileSync(
  "/Users/max/Developer/IOS/PeakLog/backend/supabase/functions/chat-send-message/agent.ts",
  "utf8",
);

test("training plan schema includes explicit exercise load type", () => {
  assert.match(
    schemaSource,
    /exerciseLoadType/,
    "Expected training plan schema to define an explicit exercise load type field",
  );
});

test("agent prompt forbids treating missing target weight as bodyweight by default", () => {
  assert.match(
    agentSource,
    /do not treat a missing target weight as bodyweight by default/i,
    "Expected agent prompt to explicitly distinguish missing target weight from bodyweight",
  );
});
