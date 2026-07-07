# Phase 1 技术方案: 编辑事件流 + GoalSpec + 生成溯源基建

> 上承 ADR-001(`docs/architecture/adr-001-llm-weekly-plan-generation.md`)Phase 1;
> 前置 Phase 0 已完成(`docs/plans/2026-07-07-phase0-auth-sync-plan.md`,除 Apple 登录外全部勾选)。
> 定位:这一期**只建数据地基,不做任何生成**。目标是让 Phase 2 的 ContextBuilder 打开数据库就能拿到三样东西:结构化目标(GoalSpec)、用户对计划的编辑事件流(PlanEditEvent)、以及一张空着待写的生成溯源表(plan_generations)。

## 1. 范围

### 做

1. **GoalSpec 结构化目标**:模型 + 云表 + Profile 录入 UI + 全量同步接入。
2. **PlanEditEvent 编辑事件流**:客户端在计划被修改的唯一收口点(`LocalAppDatabase`)记录事件,append-only 推送上云。
3. **plan_generations 溯源表**:建表 + RLS,本期无人写入(Phase 2 的生成函数写)。
4. **修复计划历史被剪除的问题**(§5.3,本期发现的架构缺陷,Phase 2 硬依赖)。

### 明确不做

- 不做 LLM 生成、不做事件的消费与分析(Phase 2)。
- 不做自由文本 → GoalSpec 的 LLM 解析(Phase 3);本期录入 UI 是纯结构化 picker。
- 不做周计划轮换/归档的自动化(Phase 2 生成函数负责把旧计划置 `archived`);本期只保证轮换发生时历史不被删。
- 事件不驱动任何 UI,用户不可见。
- 不做事件保留期清理策略(数据量极小,留到有真实体量后再说)。

## 2. 总体数据流

```
用户改计划(增/删/换/改重量/重排)
   │
   ▼
LocalAppDatabase mutation(唯一收口)
   ├─ 改状态 + persist()  ──────────▶ onChange ─▶ 全量对账推送(既有路径)
   └─ appendEditEvent(...)              │
        │                               ▼
        ▼                        performPush 末尾追加:
   pendingEditEvents(随 state    ① upsert user_goal_specs(单行,PK=user_id)
   持久化;replaceAll 时显式保留)  ② insert plan_edit_events(幂等 upsert by id)
                                        │ 成功 → 本地清掉已推送的 pending
                                        ▼
                              Phase 2 ContextBuilder 直接读云表
```

关键性质:**事件是"事实"不是"状态"**,是全量状态对账模型里唯一的例外——只插入、不参与 `deleteNotIn`、不拉取回客户端(客户端不消费它)。

## 3. 数据库设计(migration `20260708000012_phase1_events_goalspec_generations.sql`)

### 3.1 `user_goal_specs` — 每用户一行

| 列 | 类型 | 说明 |
|---|---|---|
| `user_id` | uuid **PK**, FK auth.users CASCADE | PK 即 user_id,客户端天然知道主键,upsert merge-duplicates 直接命中 |
| `objective` | varchar(32) | `muscle_gain / strength / fat_loss / endurance / general` |
| `days_per_week` | int, CHECK 1–7 | |
| `session_minutes` | int, CHECK 15–240 | |
| `equipment` | text[] | `barbell / dumbbell / machine / cable / kettlebell / bodyweight_only`(对齐客户端 `Equipment` rawValue) |
| `focus_areas` | text[] | 对齐 `MuscleGroup` rawValue |
| `experience` | varchar(16) | `beginner / intermediate / advanced` |
| `note` | text | 自由补充(与 `profiles.fitness_goal_summary` 并存,见 G1) |
| `created_at / updated_at` | timestamptz | moddatetime 触发器 |

RLS:`FOR ALL USING (user_id = auth.uid()) WITH CHECK (user_id = auth.uid())`。**吸取 Phase 0 Bug 1/2 的教训**:这张表由客户端创建首行,必须有 INSERT 能力且 upsert 的冲突键就是 PK——所以 PK 设计为 `user_id` 而不是独立 id,从根上避开 profiles(无 INSERT 策略)和 user_preferences(唯一键≠PK)踩过的两个坑。

服务端 CHECK 只做宽松的 sanity(数值范围),严格校验放客户端——过紧的服务端约束会制造"毒丸行"(见 SY6)。

### 3.2 `plan_edit_events` — append-only 事件流

| 列 | 类型 | 说明 |
|---|---|---|
| `id` | uuid PK | 客户端生成,幂等键 |
| `user_id` | uuid, FK auth.users CASCADE | 唯一的 FK |
| `plan_id / plan_day_id` | uuid,**无 FK** | 事件是历史事实,被引用的计划行可能被归档/删除,绝不能因 FK 被级联删除或阻塞插入 |
| `plan_date` | date | 冗余存储,脱离 plan 表可独立分析 |
| `event_type` | varchar(32) | 见 §4.2 枚举 |
| `exercise_name` | varchar(255) | 冗余(自包含) |
| `exercise_id` | text | 库 slug,可空 |
| `payload` | jsonb | before/after 快照,结构随 event_type |
| `source` | varchar(16) DEFAULT 'user' | 预留 `agent / system`(Phase 2 起 Agent 改计划也要发事件,必须能区分"用户改的"和"AI 自己改的",否则学习信号被污染) |
| `client_seq` | bigint | 客户端单调序号,同秒事件定序 + 时钟漂移兜底 |
| `occurred_at` | timestamptz | 客户端时钟 |
| `created_at` | timestamptz DEFAULT now() | 服务端时钟,双时钟并存 |

RLS:**只有 INSERT(WITH CHECK own)和 SELECT(own)两条策略,刻意不给 UPDATE/DELETE**——append-only 由 RLS 在服务端强制,客户端 bug 也改不掉历史。索引:`(user_id, occurred_at DESC)`、`(plan_id)`。

### 3.3 `plan_generations` — 生成溯源(本期只建表)

`id` uuid PK、`user_id`、`plan_id`、`engine`(llm)、`model_name`、`prompt_version`、`context_snapshot` jsonb(喂给 LLM 的完整事实)、`raw_response` jsonb、`validator_verdicts` jsonb(钳制/修复记录)、`status`(draft/active/superseded/failed)、`error` text、`generated_at`。

RLS:客户端只有 SELECT(own);**不建任何 INSERT/UPDATE 策略**——写入方是 Phase 2 的 Edge Function(service_role,绕过 RLS)。这里"没有策略"是特性不是遗漏,和 profiles 的教训相同方向、相反用法。

## 4. 客户端设计

### 4.1 GoalSpec

- `Models/GoalSpec.swift`:`nonisolated struct GoalSpec: Codable, Equatable, Sendable`,字段对齐 §3.1,枚举复用 `Equipment`/`MuscleGroup` rawValue。提供 `validate()`(范围检查)与默认值(`general / 3 天 / 60 分钟 / 空器械 / beginner`)。
- `LocalAppState` 增加 `var goalSpec: GoalSpec?`,**decodeIfPresent 默认 nil**(沿用既有向后兼容模式,`local_state_decode_compat_test` 需同步补 case)。
- UI:Profile `goalSection` 下新增入口 → `GoalSpecEditorScreen`(picker 表单:目标类型、每周天数、单次时长、器械多选、重点部位多选、经验、备注)。保存走新增的 `ProfileServiceProtocol.updateGoalSpec(_:)`(记得同步补 4 处 mock,见测试惯例 memory)。
- 保存成功后**不触发任何计划重建**(现 `updateFitnessGoalSummary` 的 `rebuildPlan` 行为不扩散到 GoalSpec;生成是 Phase 2 的事)。

### 4.2 PlanEditEvent 与记录点

`Models/PlanEditEvent.swift` + 事件类型:

| event_type | 触发方法(均在 `LocalAppDatabase`) | payload 要点 |
|---|---|---|
| `exercise_added` | `addPlannedExercises`(每个 draft 一条) | 名称/slug/loadType/全部目标组 |
| `exercise_removed` | `deletePlannedExercise` | 被删动作全量快照 + `hadCompletedSets` |
| `set_added` | `addPlannedSet` | setIndex/目标重量/次数 |
| `set_removed` | `deletePlannedSet` | 快照 + `wasCompleted` |
| `set_target_updated` | `updatePlannedSet` | **before + after** 两份 |
| `exercises_reordered` | `reorderPlannedExercises` | before/after 两个有序名单 |
| `goal_changed` | `updateGoalSpec` / `updateFitnessGoalSummary` | before/after |

原则:
- **记录点在 `LocalAppDatabase` 内部**(mutation 的唯一收口),不在 Service 层——未来任何新调用路径自动带事件。
- **事件自包含**(denormalized):分析永远不需要 join 还活着的计划行。
- `completePlannedSet` **不算编辑事件**:执行数据已由 `completedAt + linkedExerciseSetId → exercise_sets` 完整承载,ContextBuilder 从那边算依从率;事件流只留"结构性修改"这一种语义,不混。

### 4.3 事件暂存(pending outbox)与序号

- `LocalAppState` 增加 `var pendingEditEvents: [PlanEditEvent]` 与 `var editEventSeq: Int64`(均 decodeIfPresent 默认空/0)。
- 序号在 append 时自增并随 state 持久化(重启不回退,EV3)。
- **`replaceAll` 显式保留 `pendingEditEvents` / `editEventSeq` / `goalSpec` 以外的拉取覆盖语义**——pull 只覆盖"状态",绝不能冲掉"未推送的事实"(EV1,这是本设计最容易写错的一行)。goalSpec 属于状态,由 pull 覆盖(云端为准)。
- 记录开关:`setOnChange` 扩展为 `armCloudSync(userId:onChange:)`,钩子安装的同时启用事件记录并注入 userId;`stop()` 时一并关闭。效果:DEBUG localOnly 模式与登录前的种子数据编辑**不产生事件**(EV8),登录→拉取→armed 之后的编辑才记录。
- 软上限 5000 条:超出丢最旧并计数(离线一周约几百条,正常永远碰不到;上限只防 push 长期失败下的无界增长,EV12)。

### 4.4 同步集成(`CloudSyncCoordinator` / `CloudMapper`)

`performPush` 变更:
1. 末尾追加:`upsert user_goal_specs`(单行,PK=user_id 命中 merge-duplicates);`upsert plan_edit_events`(幂等,重试不重复,EV2);两者成功后调用 `database.clearPushedEditEvents(ids:)`。
2. **事件与 goal_specs 不进 `deleteNotIn` 剪除清单**。
3. **计划历史保护(§5.3 修复)**:`deleteNotIn` 从剪除清单中移除 `training_plans`;`training_plan_days/exercises/sets` 三张子表的剪除追加过滤条件 `plan_id=eq.<activePlan.id>`(`deleteNotIn` 增加 `extraFilters: [URLQueryItem]` 参数)。语义变为:"只在当前活跃计划范围内对账,已归档的历史周计划云端只增不删"。

pull 变更:`CloudSnapshotLoader` 增加 `user_goal_specs` 拉取(单行)→ `replaceAll` 写入 `goalSpec`。`plan_edit_events` 不拉取。现有 `training_plans` 拉取已按 `status=eq.active` + `week_start_date desc limit 1`,轮换后依然只取最新活跃周,兼容。

## 5. 异常点与 Corner Case 清单

### GoalSpec(G)

| # | 场景 | 处理 |
|---|---|---|
| G1 | 已有自由文本 `fitness_goal_summary` 的老用户 | 两者并存:GoalSpec 是结构化事实源,自由文本降级为 `note` 的前身;录入 UI 首次打开时把旧 summary 预填进 `note`,不做任何自动解析(那是 Phase 3) |
| G2 | 离线修改 GoalSpec | 走既有本地先改+推送重试路径,天然覆盖;单行 upsert 幂等 |
| G3 | 不合理组合(减脂+每周7天+30分钟) | 客户端只做范围校验(1–7 天等),不做合理性判断——合理性是 Phase 2 LLM 的职责,规则写死会重蹈"规则引擎"老路 |
| G4 | 周中改目标 | 只保存 + 记 `goal_changed` 事件,**不重建当前计划**;下次生成自然吸收。要防住现有 `updateFitnessGoalSummary → rebuildPlan` 的行为被误复用 |
| G5 | 首次使用、从未填过 GoalSpec | 本地 nil、云端无行都合法;推送时 nil 则跳过 upsert;Phase 2 生成函数遇 nil 用保守默认并在教练周报里提示补填 |

### 编辑事件(EV)

| # | 场景 | 处理 |
|---|---|---|
| EV1 | **pull 的 `replaceAll` 冲掉未推送事件** | `replaceAll` 显式保留 `pendingEditEvents`/`editEventSeq`;必须有专门逻辑测试盯住这一行 |
| EV2 | 推送超时但服务端实际已写入,重试重复 | 事件 id 客户端生成,insert 走 upsert 语义,幂等 |
| EV3 | 同一秒多次编辑、时钟回拨 | `client_seq` 单调递增且随 state 持久化;分析端排序键 = (occurred_at, client_seq) |
| EV4 | 事件引用的动作/计划后来被删/归档 | 事件自包含(冗余 name/date/目标值),表设计无计划侧 FK |
| EV5 | 推完事件后、清 pending 前进程被杀 | 下次推送重放,幂等无害 |
| EV6 | 事件风暴(连续拖拽重排 10 次) | 全部记录,不做客户端去抖——合并是消费端(ContextBuilder)的自由,丢弃是不可逆的 |
| EV7 | 半程失败:goal_specs 推成功、事件失败 | 事件保持 pending,整体 push 标记失败重试;两步都幂等,顺序无所谓 |
| EV8 | DEBUG localOnly / 未登录时的编辑(含种子数据) | 记录开关与同步 arming 绑定,这些编辑不产生事件,pending 不会积累垃圾 |
| EV9 | **换账号:A 的 pending 事件在 B 的 token 下推送** | RLS `WITH CHECK user_id=auth.uid()` 会拒绝 → 整条 push 变毒丸。arming 时校验:pending 中 userId ≠ 新 userId 的事件直接丢弃(它们对 B 无意义,对 A 已不可达) |
| EV10 | 删掉动作又加回同名动作 | 两条独立事件,快照完整,分析端可辨析"犹豫"信号 |
| EV11 | Agent(Phase 2 起)修改计划 | `source` 字段本期就建好,Phase 2 的服务端写入必须带 `agent`,否则学习信号自我污染——这是给未来的硬约束,写进表注释 |
| EV12 | push 长期失败导致 pending 无界增长 | 软上限 5000,超出丢最旧并在日志计数 |
| EV13 | E2E/测试产生的事件污染真实账号 | live 验证只用带唯一标记的事件行,验证后按 id 定点删除(需 service_role;客户端 RLS 删不了,用 MCP execute_sql 清理) |

### 同步与 schema(SY)

| # | 场景 | 处理 |
|---|---|---|
| SY1 | **计划历史被全局 `deleteNotIn` 剪除**(现状真实存在,`CloudSyncCoordinator.swift:158`) | §4.4-3 修复:plans 不剪,子表剪除 scoped 到活跃 plan_id。**不修这个,Phase 2 每周轮换都会删掉上一周的计划,学习闭环无原料** |
| SY2 | 归档计划的子行与活跃计划子行同表混存 | scoped 剪除保证互不干扰;拉取只取活跃计划的子行?——否:子表拉取现在是全表拉,轮换后会把归档周的 days/exercises/sets 也拉下来错误地拼进 activePlan。**子表拉取同样要加 `plan_id=eq.<active>` 过滤**(实现时容易漏,列为必测) |
| SY3 | 服务端 CHECK 过紧 → 客户端合法值被拒 → 整条 push 永久失败(毒丸) | 服务端约束只做宽 sanity;任何新增 CHECK 必须先确认客户端校验是其严格超集 |
| SY4 | 新增 state 字段导致老版本 state 文件解码失败 | 全部 decodeIfPresent + 默认值;补 `local_state_decode_compat_test` |
| SY5 | migration 与 DTO 漂移(Phase 0 Bug 3 同类) | 上线前重跑"全表列名 vs CloudRows 逐字段核对"这一步,固化为验证清单项 |
| SY6 | `plan_generations` 误开客户端写权限 | 刻意无 INSERT/UPDATE 策略 + 表注释说明;live 验证里加一条"客户端 insert 必须 403" |

### UI(U)

| # | 场景 | 处理 |
|---|---|---|
| U1 | GoalSpec 表单半填退出 | 本地草稿不持久化,退出即弃(表单极短);保存按钮仅在 `validate()` 通过时可用 |
| U2 | 保存时离线 | 走既有模式:本地先存 + 同步状态行显示"未同步将重试";UI 不阻塞 |
| U3 | 多选器械/部位全不选 | 合法(nil 语义 = 不限),Phase 2 按"商业健身房全器械"保守假设 |

## 6. 测试与验证

**真实数据保护(硬规则,延续 Phase 0 教训)**:开发账号云端已有用户真实训练数据;所有 live 验证只做定点行操作,禁止任何 `keepIds: []` 整表清除;事件表清理走 MCP(service_role)按标记 id 删。

1. **逻辑测试(swiftc,`tests/`)**:
   - `plan_edit_event_recording_test`:每种 mutation → 断言事件类型/payload/seq 递增;completePlannedSet 不产生事件;replaceAll 保留 pending(EV1);换账号丢弃异主事件(EV9)。
   - `goal_spec_mapping_test`:GoalSpec ↔ Row 往返 + validate 边界。
   - `local_state_decode_compat_test` 补新增字段 case(SY4)。
2. **XCTest**:GoalSpec 编辑 ViewModel 流(若有);4 处 service mock 补齐后全量绿。
3. **Live 验证 harness(真实网络,surgical)**:
   - 事件:插入带标记事件 → 读回 → **尝试 UPDATE/DELETE 断言被 RLS 拒** → MCP 定点清理。
   - goal_specs:upsert 两次(改值)断言单行更新,不 409/403(直接验证 §3.1 的 PK 设计)。
   - plan_generations:客户端 insert 断言 403(SY6)。
   - **SY1/SY2 归档保护**:用 MCP 以 service_role 造一行 `status=archived` 的假历史计划(+子行)→ 跑一次真实推送 → 断言假计划及其子行仍在、activePlan 对账正常 → 定点清理。
4. **全表列名 vs DTO 核对**(SY5)+ 全量 `xcodebuild test` + 模拟器冒烟(GoalSpec 表单可达、保存后 Profile 显示)。

## 7. 实施顺序

1. [x] 后端 migration(三张表 + RLS + 索引 + 表注释),应用到线上 + 仓库同名文件(`20260708000012_phase1_events_goalspec_generations.sql`)
2. [x] 客户端模型:GoalSpec、PlanEditEvent、LocalAppState 扩展(decode 兼容)+ 事件记录收口 + arming 开关
3. [x] 同步集成:mapper 行、push 末尾两步 + 清 pending、**SY1/SY2 scoped 剪除与 scoped 子表拉取**、pull goal_spec
4. [x] GoalSpec 录入 UI + 本地化键 + `updateGoalSpec` service 方法(含唯一 mock `RecordingProfileService`)
5. [x] 逻辑测试 + live surgical 验证(§6)+ 全量回归——SY1/SY2 用真实 `CloudSyncCoordinator` + MCP 造的假归档计划端到端验证通过
6. [x] 文档:工作日志(`docs/logs/2026-07-08-phase1-edit-events-goalspec-generations.md`)、`docs/architecture/README.md` 与 `api-reference.md` 增补

## 8. 用户已拍板的点(2026-07-08)

1. **完成组是否算编辑事件**:不算——采纳方案默认判定。
2. **GoalSpec 字段集**:七个字段全部保留,`experience`/`focus_areas` 都要。
3. **事件上限 5000 丢最旧**:接受。

## 9. 实施中发现并修复的问题

- **事件表不能用 upsert**:`plan_edit_events` 只有 INSERT+SELECT 策略,`upsert`(`ON CONFLICT DO UPDATE`)即便不触发真实冲突也需要 UPDATE 权限。改用 `insertIgnoringDuplicates`(`Prefer: resolution=ignore-duplicates`,即 `ON CONFLICT DO NOTHING`),只需 INSERT 权限,对重试幂等。
- **RLS 对无策略的 UPDATE/DELETE 返回 204 而非 403**:live 验证中发现——PostgREST 对无匹配策略的 UPDATE/DELETE 请求返回成功状态码(0 行受影响),不是错误。验证不可篡改性时必须读回行内容确认未被修改,不能只看状态码。已记入 `api-reference.md` §2。
