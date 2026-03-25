# PEA-13 Dual-End Streaming Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** 同时改造 `peaklog-core` 和 `PeakLog`，让聊天链路基于 Vercel AI SDK 提供真正的流式文本体验，并在流结束后完成结构化训练解析与落库。

**Architecture:** edge function 改为“先流式生成用户可见文本，再做结构化 workout 解析并最终写入 `content_blocks`”；iOS 改为消费 assistant `processing` 状态下的 Realtime 更新，不再只显示 typing bubble。现有 `messages` 表继续作为消息事实来源，避免引入新的流式传输协议。

**Tech Stack:** Supabase Edge Functions, Deno, TypeScript, Vercel AI SDK `streamText`, Supabase Realtime, SwiftUI, Supabase Swift SDK

---

## Scope Decision

- 同时改 `peaklog-core` 和 `PeakLog`
- 优先复用现有 `messages` 表和 Realtime 订阅
- 不新增单独的 SSE 网关，除非 Realtime 增量更新在真机表现不稳定
- 尽量不改数据库 schema；优先通过多次 `UPDATE messages` 实现渐进式文本显示

## Current Baseline

- 当前 iOS 只会把 `processing && content_blocks == nil` 当作 typing bubble，见 [`/Users/max/Developer/IOS/PeakLog/PeakLog/Models/ChatMessage.swift`](/Users/max/Developer/IOS/PeakLog/PeakLog/Models/ChatMessage.swift)
- 当前订阅层只把 assistant 的 `completed/failed` 更新抛给 ViewModel，见 [`/Users/max/Developer/IOS/PeakLog/PeakLog/Services/SupabaseChatService.swift`](/Users/max/Developer/IOS/PeakLog/PeakLog/Services/SupabaseChatService.swift)
- 当前 edge function 只在模型完成后更新一次 assistant message，见 [`/Users/max/Developer/IOS/peaklog-core/supabase/functions/chat-send-message/index.ts`](/Users/max/Developer/IOS/peaklog-core/supabase/functions/chat-send-message/index.ts)

## Success Criteria

- assistant 回复在 iOS 聊天页按增量文本实时出现
- 流式过程中仍保留“正在生成”的状态
- 流结束后同一条 assistant message 最终拥有完整 `content_blocks`
- workout 数据入库、PR summary、历史页展示不回归
- 避免因为高频 DB update 造成明显卡顿或 Realtime 风暴

### Task 1: Refactor edge function into streaming + post-parse phases

**Files:**
- Modify: `/Users/max/Developer/IOS/peaklog-core/supabase/functions/chat-send-message/index.ts`
- Create: `/Users/max/Developer/IOS/peaklog-core/supabase/functions/chat-send-message/ai-provider.ts`
- Create: `/Users/max/Developer/IOS/peaklog-core/supabase/functions/chat-send-message/streaming.ts`

**Step 1: Write the failing test**

Create tests for:
- streamed text chunks are accumulated into one assistant `content`
- throttle logic reduces write frequency
- finalization path still writes `content_blocks`

Suggested test file:
- `/Users/max/Developer/IOS/peaklog-core/tests/chat-send-message-streaming.test.mjs`

**Step 2: Run test to verify it fails**

Run:

```bash
node --test /Users/max/Developer/IOS/peaklog-core/tests/chat-send-message-streaming.test.mjs
```

Expected:
- FAIL because streaming helper does not exist yet

**Step 3: Write minimal implementation**

Split backend processing into:

- `streamAssistantReply(...)`
  - uses `streamText`
  - accumulates text
  - updates `messages.content`
  - keeps `status=processing`
- `finalizeAssistantReply(...)`
  - performs structured parse from final text or second AI SDK pass
  - writes `content_blocks`
  - sets `status=completed`

Important rule:
- do not write partial `content_blocks`
- only `content` is streamed incrementally

**Step 4: Run test to verify it passes**

Run:

```bash
node --test /Users/max/Developer/IOS/peaklog-core/tests/chat-send-message-streaming.test.mjs
```

Expected:
- PASS

**Step 5: Commit**

Do not commit yet unless the user explicitly asks.

### Task 2: Choose the structured parsing strategy after stream completion

**Files:**
- Modify: `/Users/max/Developer/IOS/peaklog-core/supabase/functions/chat-send-message/index.ts`
- Modify: `/Users/max/Developer/IOS/peaklog-core/supabase/functions/chat-send-message/ai-provider.ts`

**Step 1: Write the failing test**

Add tests for both supported paths:
- final text parsed into workout object successfully
- non-workout reply results in no exercises
- parser failure does not lose already streamed plain text

**Step 2: Run test to verify it fails**

Run:

```bash
node --test /Users/max/Developer/IOS/peaklog-core/tests/chat-send-message-streaming.test.mjs /Users/max/Developer/IOS/peaklog-core/tests/chat-send-message-pr-summary.test.mjs
```

Expected:
- FAIL on missing structured finalization

**Step 3: Write minimal implementation**

Preferred strategy:

- first pass: `streamText` for conversational reply
- second pass: `generateObject` for `reply/workoutDate/exercises`

Reason:
- streaming text and strict JSON extraction have conflicting output needs
- two-phase design is easier to reason about and easier to recover from

Implementation rule:
- if second pass fails, preserve streamed `content`, set `content_blocks` to a single text block, and choose between `completed` or `failed` based on whether user-visible reply is acceptable

**Step 4: Run test to verify it passes**

Run:

```bash
node --test /Users/max/Developer/IOS/peaklog-core/tests/*.test.mjs
```

Expected:
- PASS

**Step 5: Commit**

Do not commit yet unless the user explicitly asks.

### Task 3: Update iOS subscription logic to surface in-progress assistant text

**Files:**
- Modify: `/Users/max/Developer/IOS/PeakLog/PeakLog/Services/SupabaseChatService.swift`
- Modify: `/Users/max/Developer/IOS/PeakLog/PeakLog/ViewModels/ChatViewModel.swift`
- Test: `/Users/max/Developer/IOS/PeakLog/tests/chat_view_model_optimistic_send_test.swift`

**Step 1: Write the failing test**

Add tests proving:
- assistant `processing` updates with non-empty text are surfaced to the ViewModel
- `isSending` remains true until final completion
- optimistic placeholder is replaced by the streamed assistant message rather than duplicated

**Step 2: Run test to verify it fails**

Run:

```bash
cd /Users/max/Developer/IOS/PeakLog
swift /Users/max/Developer/IOS/PeakLog/tests/chat_view_model_optimistic_send_test.swift
```

Expected:
- FAIL because current code ignores `processing` assistant updates

**Step 3: Write minimal implementation**

In `SupabaseChatService`:
- emit assistant updates for `processing`, `completed`, and `failed`

In `ChatViewModel`:
- update existing assistant row as chunks arrive
- stop using the 2-second delayed `loadMessages()` fallback as the primary rendering mechanism
- keep a conservative refresh fallback only for missed events

**Step 4: Run test to verify it passes**

Run:

```bash
cd /Users/max/Developer/IOS/PeakLog
swift /Users/max/Developer/IOS/PeakLog/tests/chat_view_model_optimistic_send_test.swift
```

Expected:
- PASS

**Step 5: Commit**

Do not commit yet unless the user explicitly asks.

### Task 4: Update the chat UI to render streamed text before final blocks arrive

**Files:**
- Modify: `/Users/max/Developer/IOS/PeakLog/PeakLog/Models/ChatMessage.swift`
- Modify: `/Users/max/Developer/IOS/PeakLog/PeakLog/Views/Chat/ChatScreen.swift`
- Modify: `/Users/max/Developer/IOS/PeakLog/PeakLog/Views/Chat/MessageBubbleView.swift`
- Test: `/Users/max/Developer/IOS/PeakLog/tests/chat_message_pr_summary_test.swift`

**Step 1: Write the failing test**

Add focused tests or preview assertions for:
- `processing + text` assistant message renders text bubble, not typing bubble
- `processing + empty text + nil blocks` still renders typing bubble
- `completed + contentBlocks` still renders final structured content

**Step 2: Run test to verify it fails**

Run:

```bash
cd /Users/max/Developer/IOS/PeakLog
swift /Users/max/Developer/IOS/PeakLog/tests/chat_message_pr_summary_test.swift
```

Expected:
- FAIL because current `isTyping` is too strict for streamed content

**Step 3: Write minimal implementation**

In `ChatMessage`:
- redefine `isTyping` to mean “assistant processing with no visible text and no blocks”

In `ChatScreen`:
- only show `TypingBubbleView` when `message.isTyping == true`

In `MessageBubbleView`:
- when `contentBlocks` is empty but `message.text` has content, render text immediately
- when final `contentBlocks` arrive, keep existing card rendering

**Step 4: Run test to verify it passes**

Run:

```bash
cd /Users/max/Developer/IOS/PeakLog
swift /Users/max/Developer/IOS/PeakLog/tests/chat_message_pr_summary_test.swift
```

Expected:
- PASS

**Step 5: Commit**

Do not commit yet unless the user explicitly asks.

### Task 5: End-to-end verification for streaming behavior

**Files:**
- No code changes required

**Step 1: Run backend locally**

Run:

```bash
cd /Users/max/Developer/IOS/peaklog-core
supabase start
supabase functions serve chat-send-message --env-file .env.local
```

**Step 2: Run iOS app**

Open `PeakLog.xcodeproj` and send a workout message.

Expected:
- assistant bubble starts as typing only
- within a short delay, text begins appearing incrementally
- after generation finishes, structured workout card replaces or supplements plain text as designed

**Step 3: Regression checks**

Verify:
- no duplicate assistant rows
- history page still shows saved workout
- failed generations still show a readable fallback
- rapid chunk updates do not cause visible list jumpiness

## Risks and Notes

- 频繁写 `messages.content` 可能导致 Realtime 更新过多，必须加节流，建议 300-500ms 或按字符阈值写入。
- 如果 `content_blocks` 最终替换掉 plain text，UI 需要定义清楚是“保留文本块 + workout card”，还是“只保留结构化块”。建议保留 text block，避免消息视觉闪烁。
- 两阶段模型调用会增加 token 成本，但换来更稳定的流式体验和更清晰的职责边界。

## Deployment Notes

- 该方案需要同时上线 `peaklog-core` 和 `PeakLog`
- App Store/TestFlight 版本未更新前，线上 edge function 最好兼容旧客户端
- 推荐先让 edge function 对旧客户端继续可用，再发布 iOS 流式版本
- 完成后需要分别确认：
  - `PeakLog` 是否需要提交 commit
  - `peaklog-core` 是否需要推送到 Supabase 线上
