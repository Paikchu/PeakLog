# Phase 0 技术方案: Apple 登录恢复 + 云端直写同步 + 数据库精简

> 前置于 ADR-001(LLM 每周计划生成)。生成链路在服务端,数据必须先可靠地在线上。
> 关联文档: `docs/architecture/adr-001-llm-weekly-plan-generation.md`、`docs/logs/2026-07-04-supabase-apple-auth-restore.md`、`docs/logs/2026-07-04-temporary-auth-bypass.md`
>
> 2026-07-07 修订:当前本地与线上均为测试数据,**不做旧数据迁移、不做脏集推送/LWW 冲突合并**,同步模型简化为"云端直写 + 本地缓存"。数据库清理已实际执行(见 §2)。

## 1. 总体设计:云端为主,本地只是缓存

登录后云端 Postgres 是唯一事实源(single source of truth),`LocalAppDatabase` 降级为只读缓存 + 离线展示:

```
SwiftUI Views ──▶ ViewModels ──▶ Remote*Service(写云端,成功后回写本地缓存)
                                      │ 失败 → 向用户报错,不写本地(UI 与云端保持一致)
                                      ▼
                        Supabase PostgREST + RLS(用户 JWT)
                                      ▲
                 pull: 登录时/回前台全量拉取 → 覆盖写入 LocalAppDatabase
```

- **写路径**:所有 mutation 先写云端(upsert by id,客户端生成 UUID),服务器确认后更新本地缓存。写失败(离线/超时)直接向用户提示重试,不做本地暂存队列——这是有意的取舍,见 §5-E1。
- **读路径**:UI 一律读 `LocalAppDatabase`;登录成功、App 回前台时全量拉取该用户数据覆盖本地缓存(个人训练数据量级很小,一年数据也只是几百行,不需要增量水位线)。
- **不做**:脏集/outbox、LWW/`edited_at`、墓碑、迁移状态机、re-key——单一事实源在云端后,这些机制失去存在理由。删除就是云端硬删(RLS `FOR ALL` 已允许),成功后本地移除。
- **现有本地测试数据**:不上云。首次登录后本地缓存直接以云端(空)状态重建;种子数据仅保留给未登录的 DEBUG 模式。

## 2. 数据库设计(已于 2026-07-07 实际执行)

### 2.1 清理原则

线上核查结果:所有 public 表 0 行、auth.users 0 个、无已部署 Edge Function——没有需要保留或搬迁的数据,清理只涉及结构。聊天已从产品中移除(2026-07-06 remove-chat-code),为聊天管线建的表全部删除。

### 2.2 已删除(migration `20260707000009_remove_chat_pipeline_add_custom_exercises.sql`,已应用到 `fqyurmsuvtdafbnynurg`)

| 对象 | 原用途 |
|---|---|
| `conversations` / `messages` / `attachments` | 聊天会话、消息流、图片/语音附件 |
| `parse_tasks` / `parse_results` | 聊天文本 → 结构化训练记录的解析管线 |
| `conversation_pending_actions` | 聊天 agent 待确认动作 |
| `audit_logs` | 聊天 agent 操作审计(operator 概念随聊天下线) |
| `workout_sessions.source_message_id` / `.parse_status` / `.confirmation_status` | 记录来源于哪条聊天消息及解析确认状态 |
| `running_workouts.source_message_id`、`training_plans.source_message_id` | 同上 |
| `update_conversation_last_message_at()` 函数 | 维护会话最后消息时间 |
| `handle_new_user()` 中的默认会话创建 | 新用户自动建 "My Workout Log" 会话(已重建函数,只建 profile/preferences/stats) |
| storage 策略 `chat_attachments_all_own` | 聊天附件桶访问策略 |

**遗留人工步骤**:`chat-attachments` storage bucket 无法用 SQL 删(Supabase 保护),需在 Dashboard → Storage 删除。`source_type`/`source` 列保留但默认值已改为 `'manual'`。

### 2.3 保留的最终表集(13 张)

| 表 | 角色 | Phase 0 同步方向 |
|---|---|---|
| `profiles`(含 `fitness_goal_summary`) | 用户资料与目标 | 双向 |
| `user_preferences` | 偏好设置 | 双向 |
| `user_stats` | 派生统计,`refresh_user_stats` 触发器维护 | 只拉 |
| `workout_sessions` → `exercises` → `exercise_sets` | 力量训练三层聚合 | 双向,客户端为主要写方 |
| `exercise_prs` | 派生 PR,触发器维护 | 只拉 |
| `running_workouts` | 跑步记录 | 双向 |
| `training_plans` → `training_plan_days` → `training_plan_exercises` → `training_plan_sets` | 周计划四层聚合(含 `exercise_load_type`、`linked_exercise_set_id`) | 双向;Phase 2 起云端 Agent 成为计划主要写方 |
| `custom_exercises`(**本次新增**) | 用户自定义动作库条目(name_en/name_zh/aliases/muscle_group/equipment/load_type/popularity,`UNIQUE(user_id, name_en)`) | 双向 |

Phase 1 将在此基础上新增 `plan_edit_events`(编辑事件流)和 `plan_generations`(生成溯源),见 ADR-001。

### 2.4 客户端 ID 约定

云端主键全部为 `uuid`。客户端今后新建实体一律 `UUID().uuidString.lowercased()` 作为 id 直接上送;不存在旧 ID 兼容问题(旧数据不上云)。`tests/local_state_decode_compat_test.swift` 所守护的旧格式解码兼容逻辑在切换到云端直写后可一并评估移除。

## 3. 认证

> 2026-07-07 修订:当前没有 Apple Developer 账号,Sign in with Apple 无法配置。开发期改用**邮箱密码登录**,认证架构对 provider 无感,后续接入 Apple 只是 `AuthView` 加一个按钮 + Dashboard 开 provider,不动架构。

1. 重新引入 supabase-swift SDK;新建 `SupabaseConfig`(URL + publishable key,复活/更新 `tests/supabase_config_test.swift`)。
2. `AuthStateManager`(@Observable):`unauthenticated / authenticating / authenticated(userId)`;SDK 负责 Keychain 会话持久化与 token 自动刷新。对 provider 无感。
3. `AuthView`(开发期形态):邮箱 + 密码表单,只调 `signIn(email:password:)`,**不做注册流程**。开发账号在 Supabase Dashboard → Authentication → Add user 手工创建(会触发 `handle_new_user()` 建齐 profile/preferences/stats)。线上 email signup 保持关闭。
4. `PeakLogApp` 恢复 Auth gate:未登录 → `AuthView`;`#if DEBUG` 保留跳过登录开关(纯本地模式,用种子数据,不触发同步)。
5. 人工收尾:Dashboard 手工创建开发账号;Dashboard 删除 `chat-attachments` bucket。
6. **推迟(等 Apple Developer 账号)**:Dashboard 开启 Apple provider;Apple Developer 给 `com.max.PeakLog` 开 Sign in with Apple capability;`AuthView` 增加 `signInWithIdToken(provider: .apple, idToken:, nonce:)` 入口。注意 App Store 上架前必须完成(有第三方登录时 Apple 强制要求提供 Sign in with Apple)。

## 4. 客户端改动

1. **Service 层换实现**:`LocalProfileService` / `LocalWorkoutService` / `LocalTrainingPlanService` 等替换为 `Remote*Service`(Supabase 直写 + 缓存回写)。Service 协议不变,ViewModel 无感;DEBUG 跳过登录模式继续注入 Local 实现——这正是 `service_layer_mock_boundary_test` 守护的边界。
2. **`LocalAppDatabase` 角色调整**:增加 `replaceAll(with:)` 全量覆盖入口(pull 用)与 `boundUserId` 字段;登录用户模式下不再是事实源。
3. **拉取器 `CloudSnapshotLoader`**:登录成功与 `scenePhase == .active` 时,按表拉取该用户全部数据(PostgREST 按 `user_id` 由 RLS 隐式过滤),组装成 `LocalAppState` 覆盖缓存。聚合按父→子顺序拉取后在客户端组装。
4. **写接口逐条落云**:训练记录的"完成一组"(计划组完成回写 `completed_at` + `linked_exercise_set_id`)是最高频写点,注意一次 UI 操作 = 一次云端往返,需要在 UI 上做乐观展示 + 失败回滚提示。

## 5. 异常场景清单

比原方案大幅缩短——单一事实源消掉了整类冲突问题:

| # | 场景 | 处理 |
|---|---|---|
| E1 | **离线/弱网时写入** | 写失败即时报错,UI 回滚,由用户稍后重试。**接受的风险**:健身房无网时无法记录训练。若实际使用中痛,再补最小重试队列(设计上 Service 协议不变,可后加) |
| E2 | 写请求超时但服务端实际已写入 | 所有写都是 upsert by 客户端生成的 uuid,重试幂等无重复 |
| E3 | 聚合写(session + exercises + sets)半程失败 | 父先子后;残留的无子聚合在下次全量 pull 时以云端状态为准展示;记录一组失败不影响已记录的组 |
| E4 | token 刷新失败/会话吊销 | 回到 `AuthView`;本地缓存保留供只读展示,恢复登录后全量 pull 覆盖 |
| E5 | 换 Apple ID 登录(与 `boundUserId` 不符) | 清空本地缓存后以新账号 pull 重建;因本地只是缓存,无数据归属风险,提示即可 |
| E6 | 卸载重装/新设备 | 登录 → 全量 pull,天然覆盖 |
| E7 | 本地缓存 JSON 损坏 | 登录态下直接全量 pull 重建;禁止回落种子数据 |
| E8 | `user_stats` / `exercise_prs` 派生数据 | 只拉不推,云端触发器唯一写方 |
| E9 | 客户端携错 user_id 的写入 | RLS 兜底,写不进别人的行 |
| E10 | 两设备同时在线编辑同一实体 | upsert 后写覆盖先写;回前台 pull 收敛。单用户场景接受,不做合并 |

## 6. 实施顺序

1. [x] 线上数据库清理 + `custom_exercises` 新增(migration 已应用,本仓库已同步同名文件)
2. [x] Dashboard 人工收尾:开发账号已创建(`yzh5277@outlook.com`);`chat-attachments` bucket 已删除(核查线上仅剩 `avatars` 桶)
3. [x] 认证地基 + Auth gate + 邮箱密码登录(改用 URLSession 直连,不引入 SPM 包;日志见 `docs/logs/2026-07-07-phase0-auth-gate.md`)
4. [x] 云端数据服务:`SupabaseDataClient` + `CloudSnapshotLoader` 全量拉取 + `LocalAppDatabase.replaceAll` + 本地先改/全量对账推送(日志见 `docs/logs/2026-07-07-phase0-cloud-data-sync.md`;写模型对方案做了"本地先改→全量推送"的务实反转)
5. [x] 集成粘合的 App 内真实流验证 + 用户同步状态可见性。验证过程发现并修复 4 个真 bug(profiles/user_preferences upsert 撞 RLS/唯一键、training_plan_exercises 缺列、登录后到推送钩子安装之间的竞态窗口),并补齐了"本地先改"写模型下用户看不到云端同步状态的缺口(新增 `CloudSyncStatus` + Profile 页指示行)。用户已用真实账号记录当天计划,验证全程该数据未被触碰。日志见 `docs/logs/2026-07-07-phase0-cloud-sync-verification-fixes.md`。
6. [x] 异常路径验收(隔离环境,不碰真实账号数据):E1 离线写入(本地成功、云端软失败、不崩溃、自动重试)、E4 token 失效强制登出、E5/E10 经代码走查确认(pull-always-first 顺序、deleteNotIn 编码)但未做真实多账号/多端 live 测试——见日志"待办"。
7. [x] 全量 `xcodebuild test` 通过(每次改动后复跑,持续绿)
8. [ ] (待 Apple Developer 账号)接入 Sign in with Apple + 真机冒烟(§3-6)

## 7. 明确不做(Phase 0 边界)

- 不做离线写队列/脏集/LWW/墓碑/迁移状态机(§1 的取舍;E1 是已知代价)。
- 不做实时推送(Realtime);前台全量 pull 的最终一致已满足"计划提前一晚同步到位"。
- 不迁移任何本地测试数据上云。
- 不动 Live Activity 与 Today 交互逻辑。
