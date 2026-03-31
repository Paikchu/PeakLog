## 1. 架构与产品风险（优先）

**纯对话回复时，assistant 行可能永远停在 `processing`**

- 占位 assistant 消息在流式开始前就插入为 `status: "processing"`（见 `index.ts` 约 261–276 行）。
- 只有 `commit_workout` 的 `execute` 路径会把同一条 assistant 消息更新为 `completedpersistCommitWorkoutInTool`）。
- 注释写明「非 commit 回复保持 processing，UI 用 SSE」（约 429–431 行），即 **DB 状态依赖客户端用 SSE 拼完再写回**。若客户端断线、杀进程、或只依赖 Realtime 而没做最终 PATCH，会出现 **长期 processing / 与 UI 不一致**。
- **建议**：在 edge 侧 `streamText` 的 `onFinish` 里，当未调用 `commit_workout` 时，用最终 `text` 更新同一条 assistant 消息`content` / `content_blocks` / `completed`）；或明确把「仅 SSE、不写库」定为规范并在超时任务里扫 `processing` 兜底。

*`onError` 里对 DB 的 `update` 是 fire-and-forget**

```336:351:/Users/max/Developer/IOS/peaklog-core/supabase/functions/chat-send-message/index.ts

    onError: ({ error }) => {

      console.error("Agent stream error:", error);

      void supabaseAdmin

        .from("messages")

        .update({

```

- `void` 未 `await`，进程收尾或冷启动时可能 **来不及落库**。
- **建议**`await` 该更新，或写入队列/重试；至少对关键路径避免丢更新。

**SSE 错误把异常直接回给客户端**

```407:410:/Users/max/Developer/IOS/peaklog-core/supabase/functions/chat-send-message/index.ts

      } catch (streamErr) {

        console.error("SSE forward error:", streamErr);

        send({ type: "error", message: String(streamErr) });

```

- 可能泄露内部信息（栈、连接错误等）。**建议**：对外固定文案，细节只打日志。

---

## 2. AI SDK / Agent 形态

**当前是 `streamText` + 单工具 + `stopWhen: stepCountIs(2)`，不是 skill 里强调的 `ToolLoopAgent`**

- 对你现在「只有一个 `commit_workout`、最多一轮工具」的场景`streamText` 是合理子集。
- **风险在步数**`stepCountIs(2)` 若未来加第二个工具、或模型需要「先说明再工具再总结」多步，会被 **静默截断**。升级 agent 时应改为显式 `maxStepsstopWhen` 策略或迁到 `ToolLoopAgent`（以你锁定的 `ai` 版本文档为准）。
- *`npm:ai` / `npm:@ai-sdk/deepseek` 未锁版本**：Deno 每次可能解析到不同 minor，与 skill「以源码/文档为准」冲突，易出现 **线上与本地行为不一致**。**建议**：改为 `npm:ai@x.y.z` 等形式固定版本。

**流事件解析偏脆**

- `fullStream` 分支里用 `part as Record<string, unknown>` 再按 `type` 分支，并兼容 `delta` / `inputTextDelta` / `argsTextDelta`（约 367–402 行）。SDK 升级时字段名若变，容易 **静默丢事件**。**建议**：封装成小函数 + 单测/类型收窄，或只依赖文档里稳定的事件字段。

**工具入参校验重复**

- `inputSchema`（Zod）与 `execute` 里 `parseCommitWorkoutToolInput` 双轨`tools.ts`）。**好处**是防御畸形；**代价**是两套规则需同步`schema.ts` 里 `getCommitWorkoutToolInputSchema` 与手写 `parseCommitWorkoutToolInput` 已存在重复逻辑倾向，长期建议 **以 Zod 为唯一真源**，execute 内只做 `schema.safeParse`。

*`extractCommitWorkout` + `onFinish` 失败兜底**

- 在模型产出了 `commit_workout` 但持久化未跑通时，把消息标为失败（约 313–334 行）是合理的产品逻辑；注意 `onFinish` 里 `toolCalls` 形状是否与当前 `streamText` 一致（同样建议在升级 SDK 时回归测）。

---

## 3. Supabase / Postgres 与数据一致性

*`buildWorkoutAndContentBlocks` 缺少事务**

- 流程包括`workout_sessions` 插入或选用已有`exercises` 循环插入`exercise_sets` 批量插入、RPC `refresh_exercise_prs_for_user`、再读 `exercise_prs`（约 509–690 行）。
- 任一步抛错可能导致 **已有 session/exercise 已写入但后续失败**，与「一次 commit 原子」不符。**建议**：用 **单事务**（Postgres `BEGINCOMMIT`）或 Supabase RPC 内完成「写 session + exercises + sets」，失败则全回滚。

**明显的 N+1 往返**

- 每个动作 `exercises` 一次 insert + 一次 `exercise_sets` insert（约 592–631 行）。动作多时延迟和连接占用线性增长。**建议**`exercises` 批量 insert`insert([...]).select()`）再按顺序批量 `exercise_sets`，或一条 RPC。

**查询与索引（中等优先级）**

- `loadConversationContextForAgentmessages` 上 `(conversation_id, user_id, deleted_at, created_at)` 过滤；现有 `idx_messages_conversation` 是 `(conversation_id, created_at)`（迁移 132 行）。在「单会话只属于单用户」前提下仍常够用；若行数很大，可考虑 **复合索引** `(conversation_id, user_id, created_at DESC) WHERE deleted_at IS NULL` 类优化（需用 `EXPLAIN ANALYZE` 验证）。
- `fetchRecentSavedRecordSummaries`：拉 12 条再在应用里扫 `content_blocks`（约 693–735 行）。已有 GIN（134 行），若以后要按 JSON 条件过滤，可评估 **jsonb 路径查询 + 索引** 是否比拉全块更省。

**PR 相关三次往返**

- `safeFetchExercisePRMap` → 写训练 → `safeRefreshExercisePRs`（RPC）→ 再 `safeFetchExercisePRMap`。**建议**：若 RPC 可返回「是否变化」或新快照，可减少一次读；或合并进同一事务/RPC（需看 `refresh_exercise_prs_for_user` 实现与负载）。

**安全面（你已做得较好的部分）**

- 对话校验用 `supabaseAdmin` 但带 `user_id`（约 186–191、500–502 行），避免仅靠 `conversation_id` 越权，符合 **service role 必须自带授权过滤** 的习惯。

---

## 4. 可执行的优化路线图（按性价比）

| 优先级 | 项 |

|--------|----|

| P0 | 非 tool 完成路径：在 edge `onFinish` 写回 assistant 最终文本，或客户端 + 超时任务双保险 |

| P0 | `persistCommitWorkout` 全流程事务化（或 RPC 原子写） |

| P1 | `onError` DB 更新改为可靠 await/重试 |

| P1 | 锁定 `npm:ai` / `@ai-sdk/deepseek` 版本；升级后对照当前文档测 `fullStream` 事件 |

| P2 | 批量插入 exercises/sets，减少 N+1 |

| P2 | SSE `error` 消息脱敏`stepCountIs(2)` 与多工具规划一起重审 |

| P3 | 合并/精简 PR 往返；按需加复合索引并用 `EXPLAIN` 验证 |

---

## 5. 与两个原则的对应关系（简短）

- **AI SDK**：已用 `tool` + `inputSchema`（符合新 API 方向），但整体仍是手写 `streamText` 循环而非 `ToolLoopAgent`；版本未钉、事件解析偏脆、步数上限对未来扩展是隐患。
- **Supabase Postgres**：索引底子不错；主要缺口在 **事务与批量写**、以及 **上下文/PR 的多轮查询** 是否值得收紧。

如果你希望下一步落到具体改动，我可以按「P0 先补 assistant 文本落库 + 事务」给出一版最小 diff 方案（仅 peaklog-core，不涉及 PeakLog iOS 提交）。  

按你们工作区约定：**peaklog-core 这边我不主动提交 git**；若改完 edge function，需要你确认是否要 **部署/推送到 Supabase 线上**。需要我帮你写 commit 的话，只说一声即可（仅 PeakLog 项目会按规则询问 commit）。