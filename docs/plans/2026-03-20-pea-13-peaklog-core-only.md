# PEA-13 Peaklog-Core Only Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** 在不改 iOS 客户端交互模型的前提下，把 `chat-send-message` 的 LLM 接入从手写 DeepSeek HTTP 调用切换到 Vercel AI SDK。

**Architecture:** 保持当前“iOS 调用 edge function -> 插入 placeholder -> Realtime 收最终消息”的链路不变，只替换 `peaklog-core` 内部的模型调用实现。继续由 edge function 负责消息入库、结构化解析、训练数据写入和 `content_blocks` 生成，因此不需要改 `PeakLog` 的订阅和渲染逻辑。

**Tech Stack:** Supabase Edge Functions, Deno, TypeScript, Vercel AI SDK, DeepSeek provider, Supabase Realtime

---

## Scope Decision

- 只改 `peaklog-core`
- 不改 `PeakLog` iOS 客户端
- 不改数据库 schema，除非 AI SDK 接入过程中发现必须补充 provider 配置文件
- 不改变当前用户体验：仍然是 typing bubble，最终一次性展示完整回复

## Current Baseline

- iOS 通过 [`/Users/max/Developer/IOS/PeakLog/PeakLog/Services/SupabaseChatService.swift`](/Users/max/Developer/IOS/PeakLog/PeakLog/Services/SupabaseChatService.swift) 调用 `chat-send-message`
- edge function 当前在 [`/Users/max/Developer/IOS/peaklog-core/supabase/functions/chat-send-message/index.ts`](/Users/max/Developer/IOS/peaklog-core/supabase/functions/chat-send-message/index.ts) 中直接 `fetch("https://api.deepseek.com/v1/chat/completions")`
- assistant 消息只在处理完成后写入最终 `content` 和 `content_blocks`
- iOS 只渲染 `completed/failed` assistant 更新，不消费增量文本

## Success Criteria

- `chat-send-message` 使用 Vercel AI SDK 发起模型调用
- 结构化输出行为与当前逻辑保持一致：仍然得到 `reply/workoutDate/exercises`
- `buildWorkoutAndContentBlocks`、PR summary、workout 落库逻辑不回归
- iOS 无需任何代码改动即可继续工作

### Task 1: Add AI SDK dependency shape for Supabase function

**Files:**
- Modify: `/Users/max/Developer/IOS/peaklog-core/supabase/functions/chat-send-message/index.ts`
- Create: `/Users/max/Developer/IOS/peaklog-core/supabase/functions/chat-send-message/ai-provider.ts`
- Optional Create: `/Users/max/Developer/IOS/peaklog-core/deno.json`

**Step 1: Write the failing test**

Create a focused unit seam for provider invocation so the new provider module can be tested without calling the real API.

Suggested test file:
- `/Users/max/Developer/IOS/peaklog-core/tests/chat-send-message-ai-provider.test.mjs`

Test cases:
- provider returns parsed `reply/workoutDate/exercises`
- invalid provider payload falls back to text-only response
- missing API key throws a configuration error

**Step 2: Run test to verify it fails**

Run:

```bash
node --test /Users/max/Developer/IOS/peaklog-core/tests/chat-send-message-ai-provider.test.mjs
```

Expected:
- FAIL because provider module does not exist yet

**Step 3: Write minimal implementation**

Create `ai-provider.ts` that:

- imports `generateObject` from `ai`
- uses the DeepSeek provider package if available, otherwise `createOpenAICompatible`
- builds the same prompt context currently assembled in `callDeepSeek`
- returns a typed object equivalent to current `DeepSeekWorkoutResponse`

Implementation constraints:
- keep `SYSTEM_PROMPT` in one place
- keep provider-specific config out of business logic
- return normalized errors with actionable text

**Step 4: Run test to verify it passes**

Run:

```bash
node --test /Users/max/Developer/IOS/peaklog-core/tests/chat-send-message-ai-provider.test.mjs
```

Expected:
- PASS

**Step 5: Commit**

Do not commit yet unless the user explicitly asks.

### Task 2: Replace the direct DeepSeek HTTP call with AI SDK

**Files:**
- Modify: `/Users/max/Developer/IOS/peaklog-core/supabase/functions/chat-send-message/index.ts`
- Modify: `/Users/max/Developer/IOS/peaklog-core/supabase/functions/chat-send-message/env.ts`

**Step 1: Write the failing test**

Add or extend tests to assert that background processing can consume the provider abstraction result without depending on raw OpenAI-compatible response shapes.

Suggested cases:
- structured result with exercises still reaches `buildWorkoutAndContentBlocks`
- text-only result still updates assistant message to completed

**Step 2: Run test to verify it fails**

Run:

```bash
node --test /Users/max/Developer/IOS/peaklog-core/tests/*.test.mjs
```

Expected:
- FAIL where code still references `callDeepSeek` or old fetch shape

**Step 3: Write minimal implementation**

In `index.ts`:

- remove `callDeepSeek`
- call the new provider abstraction from `processInBackground`
- keep `EdgeRuntime.waitUntil(...)` and placeholder insert flow unchanged
- keep current DB write timing unchanged: only final update writes `content_blocks`

In `env.ts`:

- add helper for provider key lookup if needed
- keep backward compatibility with existing env variable names

**Step 4: Run test to verify it passes**

Run:

```bash
node --test /Users/max/Developer/IOS/peaklog-core/tests/*.test.mjs
```

Expected:
- PASS

**Step 5: Commit**

Do not commit yet unless the user explicitly asks.

### Task 3: Harden error handling and payload compatibility

**Files:**
- Modify: `/Users/max/Developer/IOS/peaklog-core/supabase/functions/chat-send-message/index.ts`
- Test: `/Users/max/Developer/IOS/peaklog-core/tests/chat-send-message-ai-provider.test.mjs`

**Step 1: Write the failing test**

Add tests for:
- provider timeout or upstream 5xx
- malformed structured output
- no exercises returned for non-workout chat

**Step 2: Run test to verify it fails**

Run:

```bash
node --test /Users/max/Developer/IOS/peaklog-core/tests/chat-send-message-ai-provider.test.mjs
```

Expected:
- FAIL for missing fallback behavior

**Step 3: Write minimal implementation**

Ensure:
- assistant placeholder still transitions to `failed` on unrecoverable error
- fallback text remains user-friendly
- JSON/object parsing failures degrade to `reply + []`

**Step 4: Run test to verify it passes**

Run:

```bash
node --test /Users/max/Developer/IOS/peaklog-core/tests/chat-send-message-ai-provider.test.mjs
```

Expected:
- PASS

**Step 5: Commit**

Do not commit yet unless the user explicitly asks.

### Task 4: Verify end-to-end local behavior

**Files:**
- No code changes required

**Step 1: Start local Supabase**

Run:

```bash
cd /Users/max/Developer/IOS/peaklog-core
supabase start
supabase functions serve chat-send-message --env-file .env.local
```

Expected:
- local stack healthy
- function starts without module resolution errors

**Step 2: Send a manual request**

Use an authenticated request path already used by iOS or invoke from the app.

Verification points:
- user message inserted
- assistant placeholder inserted with `processing`
- assistant final row updated to `completed`
- `content_blocks` shape remains compatible with iOS

**Step 3: Smoke test the iOS app without changing code**

Open `PeakLog.xcodeproj`, run the app, send one workout message.

Expected:
- still shows typing bubble during processing
- final assistant message appears normally
- workout history and PR summary still work

## Risks and Notes

- AI SDK 在 Supabase Edge Functions 的依赖解析可能需要额外的 `deno.json` 或 JSR/NPM 兼容配置，这是本方案的主要技术风险。
- 如果 DeepSeek provider 在当前 Supabase Deno 运行时里兼容性不好，退路是使用 `@ai-sdk/openai-compatible` 包装 DeepSeek OpenAI-compatible endpoint。
- 本方案不提供真正的 token streaming；它只是把 provider 接口抽象成 AI SDK，属于基础设施替换，不改变用户可见交互。

## Deployment Notes

- 这个方案只需要部署 `peaklog-core` 的 edge function
- 不需要发布新的 iOS 包
- 部署后需要在 Supabase 线上环境同步 provider 相关环境变量
- 完成后应明确询问是否需要把 `peaklog-core` 推送到 Supabase 线上
