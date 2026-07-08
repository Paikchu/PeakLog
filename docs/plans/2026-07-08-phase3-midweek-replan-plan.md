# Phase 3 技术方案: 周中动态重排

> 上承 ADR-001(`docs/architecture/adr-001-llm-weekly-plan-generation.md`)决策 #7/#8 与 Action Item 4;
> 前置 Phase 0(登录+同步)、Phase 1(GoalSpec/编辑事件/溯源表)、Phase 2(周生成主链路+cron)均已完成并提交。
> 定位:计划不再是周日晚定稿后一周不变的静态物——用户状态不好、时间有限、或干脆没练时,系统当场(一键触发)或当晚(行为推断兜底)重排本周剩余天,把错过的训练量合理重新分配,同时绝不触碰任何已发生的执行数据。

## 1. 范围

### 做

1. **`replan_plan_days` RPC**:事务化替换当前周计划中若干"可重排天"的内容,数据库级强制 C31 不变量(见 §3.1)。
2. **`generate-weekly-plan` Edge Function 扩展**:新增 `mode: 'replan'`——复用既有 ContextBuilder/Validator/LLM 管线,scope 缩小为本周剩余天;新增用户 JWT 鉴权路径(仅限重排自己的计划);重排专用 prompt(`replan-v1`)与频控。
3. **Today 页一键结构化输入**(ADR 决策 #7 的"优先"触发源):跳过今天 / 状态不好 / 时间有限,三个按钮级事件,不是聊天。
4. **行为推断兜底触发**(ADR 决策 #7 的"兜底"):复用既有 hourly cron——用户本地 21:00 后,若今天是训练日且云端零完成记录,自动重排明天起的剩余天。
5. **同步冲突防护(revision guard)**:`training_plans` 增加 `revision` 列,服务端重排时递增;客户端推送计划子表前核对 revision,不一致先拉取合并再推——堵住"旧客户端推送冲掉重排结果"的洞(§4.3,这是 Phase 2 C9 的严重化版本,不能再作为已知行为接受)。
6. **溯源与学习闭环**:重排写 `plan_generations`(新增 `kind='replan'`)+ 以 `source='agent'` 记录结构变更事件;用户的一键信号以 `source='user'` 记录——下周日的周生成能同时看到"用户发了什么信号"和"Agent 当时怎么响应的"。

### 明确不做

- 不做 RPE/主观疲劳度量表(ADR 决策 #8)——一键输入的信号枚举即扩展位,后续加新信号不动架构。
- 不做自由文本目标的 LLM 解析(待拍板:若用户要求可并入本期,见 §8;默认后置)。
- 不做指标看板(ADR Action Item 5,另立项)。
- 不做重排预览/确认流——一键即生效(可撤销性由"再点一次重排"与编辑事件历史兜底);预览流会把按钮级事件膨胀成审批流,违背"AI 在背后做事"。
- 不做聊天(不变的前提)。

## 2. 总体架构与数据流

```
触发源 A: Today 页一键输入(优先)                触发源 B: 行为推断(兜底)
  用户点 [跳过今天|状态不好|时间有限]               既有 pg_cron 每小时唤醒
  │ 1. 本地记录 user 信号事件(既有事件管线)          │ 用户本地 21:00~23:00 &&
  │ 2. 直接 POST Edge Function                      │ 今天是训练日 && 云端今天零完成组
  │    Authorization: Bearer <用户JWT>              │ && 今天无重排记录
  │    {mode:'replan', signal:'skip_today',...}     │
  ▼                                                ▼
generate-weekly-plan (mode='replan')
  │ 1. 鉴权: 用户 JWT → auth.uid() 必须 == 目标 user_id(cron 路径仍走 generation-secret)
  │ 2. 频控: 当日 replan 生成数 ≥ 3 → 429
  │ 3. 确定可重排天集合(C31): plan_date ≥ 今天(用户时区) 且 该天零完成组
  │ 4. ContextBuilder(复用): 本周计划全貌 + 今天为止的实际完成 + 信号 + 剩余天集合
  │ 5. LLM(replan-v1 prompt): 只输出可重排天的新内容; Validator 复用(天数校验放宽为
  │    "输出天集合 == 可重排天集合", 钳制/动作库校验不变); repair ≤2; 失败 → 不改动
  │    (重排的 fallback 是"保持原计划", 不是硬造一个)
  │ 6. replan_plan_days RPC: 单事务替换目标天内容 + revision++ (C31 数据库级复核)
  │ 7. 溯源: plan_generations(kind='replan', trigger, signal) + source='agent' 编辑事件
  ▼
客户端: 一键路径调用返回后立即 pull() → UI 即时刷新为新计划
        兜底路径次日打开 App 时 pull 自然带下来
```

关键性质:**重排是"替换未来",不是"修改过去"**——任何有完成记录的组、任何已过去的天,都在可重排集合之外,且由数据库层复核(不信任函数计算),与 Phase 2 C21 同一哲学。

## 3. 服务端设计

### 3.1 `replan_plan_days(p_user_id uuid, p_plan_id uuid, p_days jsonb, p_expected_revision int)` RPC

单事务内:

1. `auth.role()` 必须是 `service_role`(沿用 Phase 2 的双层防护:显式 REVOKE anon/authenticated/PUBLIC + 函数内检查——那次 anon 默认授权的教训写在 20260708000013 的注释里,新函数从第一天就带上)。
2. 计划必须属于该用户、`status='active'`、且是**当前周**(`week_start_date == 本周一`,用户时区)——重排只对正在进行的周有意义,未来周该由周生成负责,历史周不可触碰。
3. **C31 硬性不变量(数据库级,每个目标天独立复核)**:`p_days` 中每一天必须满足 `plan_date >= 今天(用户时区)` 且 该天现存的 `training_plan_sets` 中**不存在任何 `completed_at IS NOT NULL` 或 `linked_exercise_set_id IS NOT NULL` 的行**。任何一天不满足 → `RAISE EXCEPTION` 回滚全部。已完成的执行数据在物理上不可能被这条路径改写——删除范围永远是"零完成记录的天"的行。
4. 乐观锁:`training_plans.revision != p_expected_revision` → 拒绝(函数读取上下文和写入之间用户可能推送了新编辑;拒绝后由函数层决定是否重读重试一次)。
5. 替换:仅对 `p_days` 中的天,删除其现有 exercises/sets 行(days 行保留 id 只更新 title/focus,避免客户端本地引用悬空),插入新内容;`revision = revision + 1`;不在 `p_days` 中的天一行不碰。
6. 返回 `{planId, replannedDates, newRevision}`。

### 3.2 Edge Function 扩展(同一个 `generate-weekly-plan`,不另立函数)

- **请求**:`{mode: 'replan', user_id, signal?: 'skip_today'|'low_energy'|'time_limited', dry_run?: bool}`。`mode` 缺省 `'weekly'`,既有行为完全不变。
- **鉴权双路径**:既有 `x-generation-secret`(cron/运维)不变;新增 `Authorization: Bearer <用户JWT>` 路径——用 service client 的 `auth.getUser(jwt)` 解析,`uid` 必须等于 `user_id`,且该路径**只允许 `mode='replan'`**(周生成仍然是纯服务端权限,客户端永远不能触发)。
- **频控**:`plan_generations` 中该用户今日 `kind='replan'` 计数 ≥ 3 → 429。防误触与成本失控;行为推断触发每天至多 1 次(见 §3.4),与一键共享同一配额。
- **重排管线**(复用率最大化):
  - ContextBuilder 复用,追加:本周计划全貌(含每天完成状态)、触发信号、可重排天集合、"今天已过去几个训练日/漏了什么"。
  - `prompt.mjs` 新增 `REPLAN_SYSTEM_PROMPT` + `REPLAN_PROMPT_VERSION='replan-v1'`:核心指令——把错过/将错过的训练量在剩余天里合理重新分配,尊重恢复间隔,**宁可减量不可硬塞**(剩余天塞不下就明确放弃部分量并在 coach 说明里解释);`signal='time_limited'` 时今天课表压缩到 ~30 分钟核心动作;`skip_today` 时今天置休息日;`low_energy` 时今天减量 30-40% 或换轻恢复日,由 LLM 决策。
  - Validator 复用:动作库校验、钳制、reps 范围全部不变;结构校验从"恰好 7 天"改为参数化"输出天集合 == 期望天集合"。
  - **失败兜底与周生成不同**:repair 2 次后仍失败 → **保持原计划不动**,只写一条 `status='failed'` 的溯源行。周生成的 fallback 是"必须有计划可练"所以硬造;重排的原计划本身就是合法状态,失败时"什么都不做"才是安全的。
- **溯源**:`plan_generations` 加列 `kind varchar(16) NOT NULL DEFAULT 'weekly' CHECK (kind IN ('weekly','replan'))` + `trigger varchar(16)`(`'user_tap'|'inference'`)+ `signal varchar(16)`;`context_snapshot` 含重排前的剩余天原貌(可对比"改了什么")。
- **agent 编辑事件**:重排成功后,对每个被改动的天写一条 `plan_edit_events`(`source='agent'`, `event_type='agent_replan_day'`, payload 含 signal/trigger/前后动作清单摘要)——下周日的周生成上下文里,编辑事件摘要会自然呈现"周三用户说时间有限,Agent 把腿部量挪到了周五",这是学习闭环的原料。

### 3.3 行为推断触发(cron 路径内联,不新增调度)

既有 hourly cron 的全量模式中,对每个用户在窗口判断后追加第二个判断分支:本地时间 ∈ [21:00, 23:00) 且今天在其当前周计划中是训练日(有动作的天)且该天零完成组且今日尚无任何 `kind='replan'` 生成记录 → 以 `trigger='inference'`、`signal=null` 跑一次重排(scope 从**明天**起——今天已经过去了,推断路径不改今天,这点与一键不同)。推断故意保守:只处理"整天没练"这一种明确信号,"完成率显著缩水"的判断阈值主观性强,首期不做,观察真实数据后再说。

### 3.4 与 Phase 2 既有机制的关系

- C21(周生成不碰当前/历史周)**不放宽**:`install_generated_plan` 原样不动,重排走的是职责完全不同的新 RPC,两条写路径各自带各自的不变量——C21 管"周粒度安装",C31 管"天粒度替换",没有共享的放行开关。
- 周日晚的边界:周日 20:00 后周生成窗口打开、同一晚 21:00 行为推断也可能触发——两者目标周不同(下周 vs 本周剩余的周日),互不冲突;且周日晚重排剩余天集合近乎为空,函数对"可重排天集合为空"直接返回 no-op。

## 4. 客户端改动

### 4.1 Today 页一键输入(本期唯一的 UI 增量)

`TodayWorkoutScreen` 工具栏新增一个入口(SF Symbol 如 `slider.horizontal.3`),弹出三选项菜单:跳过今天 / 状态不好 / 时间有限。点击后:

1. 经既有事件管线本地记录 `source='user'` 的信号事件(`event_type='day_signal'`,payload 含 signal)——即使后续函数调用失败,信号本身也进入学习闭环;
2. 调用新的 `PlanReplanService.requestReplan(signal:)` → POST Edge Function(带用户 JWT);
3. 成功 → 立即 `pull()` → UI 刷新,顶部短暂展示新的 coach 说明(复用现有 coach_summary/notes 展示,不新建组件);失败 → 轻提示"暂时无法调整,计划保持不变"(原计划本来就合法,失败无害)。

不做预览确认流;今天已有完成组时,菜单中"跳过今天/时间有限"置灰(C31 会拒绝,前端提前避免徒劳调用),"状态不好"仍可用(scope 自动从明天起)。

### 4.2 revision guard(冲突防护,本期客户端改动的重头)

- `TrainingPlanRow`/本地模型增加 `revision`;pull 时存下。
- `performPush` 推计划子表前,先以一个轻量请求读云端活跃计划的 `revision`:与本地一致 → 照旧推;不一致(说明服务端在本地上次 pull 之后重排过)→ **先 pull-merge 再推**——merge 沿用 Issue #1 的既有语义(本地未推送的完成记录/训练记录保留,计划结构以云端为准)。被覆盖的本地结构性编辑不会完全丢失:它的编辑事件是 append-only 的,信号依然进入下周生成的上下文。
- 一键路径因为"调用后立即 pull"天然同步,revision guard 主要防的是行为推断路径(用户睡前没开 App,凌晨推断重排,次日早上打开 App 时 `hasUnpushedChanges` 为真先推后拉的旧顺序会冲掉重排)。

### 4.3 为什么不能像 C9 一样接受不管

Phase 2 的 C9(旧客户端把归档计划推回 active)只影响一个 status 字段且每周自愈;这里不同:重排改的是**用户此刻正在执行的周**的计划内容,被旧推送整体冲掉意味着用户刚看到的调整凭空消失、且 `deleteNotIn` 会物理删除重排产生的新行——不可自愈、用户可感知、直接伤信任。必须堵。

## 5. 异常点与 Corner Case 清单

| # | 场景 | 处理 |
|---|---|---|
| C22 | 一键触发时今天已有完成组 | 前端置灰跳过/时间有限;函数端 C31 把今天排除出可重排集合,`low_energy` 自动从明天起 |
| C23 | 周日点一键(剩余天集合为空或仅剩今天) | 可重排集合为空 → 函数返回 no-op + 说明;仅剩今天且可重排 → 正常处理单天 |
| C24 | 重排 LLM 失败 | 保持原计划,写 failed 溯源行,客户端轻提示;**没有 fallback 硬造** |
| C25 | 重排与用户编辑并发(用户正在改周四,重排也在改周四) | RPC 乐观锁(expected_revision)拒绝晚到方;函数重读上下文重试一次,再失败放弃 |
| C26 | 旧客户端(无 revision 逻辑)推送 | 服务端无法强制旧客户端;本项目单开发者单设备,升级即覆盖;revision 列对旧客户端是未知列,PostgREST upsert 不带该列不会破坏它——但旧客户端的 deleteNotIn 仍有破坏力,记录为已知风险,依赖及时升级 |
| C27 | 频控耗尽后行为推断也想触发 | 共享配额,超限跳过并写 skipped 溯源;次日恢复 |
| C28 | 用户时区周界:周日 23:50 触发,函数处理时已过周一 0 点 | C31 按处理时刻的"今天"计算,过界的天自动落出可重排集合;极端情况变 no-op,无害 |
| C29 | 信号事件与函数调用一个成功一个失败 | 两者独立:信号事件走本地管线必达(学习闭环不丢);函数失败计划不变,可重试 |
| C30 | dry_run 支持 | `mode='replan'` 同样支持 `dry_run`,只写溯源不动计划——prompt 调优的迭代环与 Phase 2 相同 |
| C31 | **重排误碰已完成数据/过去天(本期的硬性不变量)** | §3.1:RPC 对每个目标天独立复核"日期 ≥ 今天 且 零完成组",违反即整体回滚;删除语句的 WHERE 范围物理上限定在通过复核的天内;必须有专项测试(§6-5) |
| C32 | 行为推断误判(用户练了但没同步) | 推断只看云端数据,离线未推送时确实会误判——但重排 scope 从明天起,今天的离线数据推上来后原样保留;次日用户看到的调整基于"系统当时所知",且编辑事件可回溯;接受此边界 |
| C33 | plan_generations 的 kind 列迁移 | 既有行 DEFAULT 'weekly' 回填,CHECK 约束同migration 加上;Phase 2 已写入的行语义正确 |

## 6. 测试与验证

**真实数据保护(硬规则不变)**:开发账号有真实训练数据;重排类测试一律先 `dry_run`;真实重排用 `user_id` 定点;C31 专项验证用带标记的临时测试行,事后按 id 精确清理。

1. **node --test 扩展**:validator 参数化天集合校验;replan prompt 的 buildUserMessage;ContextBuilder 的剩余天/完成状态装配;频控与鉴权逻辑若可纯函数化则一并覆盖。
2. **RPC 层 live 验证**(模拟 service_role 上下文,同 Phase 2 方法):合法重排单天/多天;C31 专项——目标天含已完成组 → 拒绝且零副作用;目标天在过去 → 拒绝;revision 不匹配 → 拒绝;替换后未涉及天逐字节不变。
3. **Edge Function live**:用户 JWT 路径鉴权边界(别人的 user_id → 403;secret 路径不受影响);`dry_run` 重排人工评审输出质量(replan-v1 prompt 迭代环);频控第 4 次 → 429。
4. **端到端**:模拟器一键"时间有限"→ 计划即时刷新为压缩版,今天之前/已完成数据分毫未动;行为推断路径手动触发验证。
5. **revision guard**:构造"服务端已重排 + 本地持旧状态且有未推送变更"的场景,确认推送前检测到 revision 不一致、先拉后推、重排结果存活、本地完成记录也存活。
6. **回归**:`node --test` 全绿;`xcodebuild test` 全绿;Phase 2 周生成路径(mode 缺省)行为不变的确认。

## 7. 实施顺序(稳步推进,每步可独立验收)

1. [x] **migration**:`plan_generations` 加 `kind/trigger/signal` 列;`training_plans` 加 `revision`;`replan_plan_days` RPC(含 C31 + 乐观锁 + 权限模式)
2. [x] **RPC live 验证**:C31 专项 + 乐观锁 + 零副作用确认(不依赖函数与客户端)
3. [x] **纯函数层扩展 + node 测试**:validator 参数化、REPLAN prompt、ContextBuilder 剩余天装配
4. [x] **Edge Function 扩展**:mode='replan' + 用户 JWT 鉴权 + 频控 + dry_run;部署后对开发账号 dry_run 迭代 replan-v1 prompt
5. [x] **客户端 revision guard**:模型/Row 加列、推送前核对、pull-merge 语义确认(+逻辑测试)
6. [x] **客户端一键 UI + PlanReplanService**:Today 页入口、调用、即时 pull、置灰逻辑
7. [x] **首次真实重排**:定点触发 → SQL 全面核查(模拟器端到端走查留待人工,见日志"遗留")
8. [x] **行为推断接入 cron 路径** + 失败演练(C24/C25/C27)+ 文档(工作日志、README、api-reference)

## 8. 用户已拍板的点(2026-07-08)

1. **一键选项集**:三个信号全做(跳过今天/状态不好/时间有限),与 ADR 决策 #7 一致;三者共享同一条重排管线,差异在 prompt 的处理策略。
2. **行为推断兜底**:本期一并做,收窄为只处理"整天零完成"这一种明确信号(C32 的误判边界已记录并接受)。
3. **交互形态**:一键即改,无预览确认流——失败时计划保持不变无害,改动本身有轻提示 + coach 说明,且可再次触发调整。
4. **自由文本目标解析**:不并入本期,单独排期(与重排正交,GoalSpec 结构化录入已可用,解析属体验增强)。

按此方案实施,顺序见 §7。
