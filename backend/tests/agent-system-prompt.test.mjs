import test from "node:test";
import assert from "node:assert/strict";
import fs from "node:fs";
import path from "node:path";

const repoRoot = path.resolve(import.meta.dirname, "..");

const agentSource = fs.readFileSync(
  path.join(repoRoot, "supabase/functions/_shared/agent.ts"),
  "utf8",
);

test("agent prompt explicitly treats common ab/core movements as bodyweight logs", () => {
  assert.match(
    agentSource,
    /卷腹, 仰卧起坐, 平板支撑/,
    "Expected prompt to explicitly include common Chinese bodyweight movements",
  );
  assert.match(
    agentSource,
    /记录一组卷腹十个/,
    "Expected prompt to include a direct crunch logging example",
  );
});

test("agent prompt prioritizes merging short follow-up context into the previous workout", () => {
  assert.match(
    agentSource,
    /"10个", "10次", "3组", "20kg", "体重", "就一组"/,
    "Expected prompt to enumerate short supplement patterns",
  );
  assert.match(
    agentSource,
    /complete that same record/,
    "Expected prompt to favor completing the prior workout record",
  );
});
