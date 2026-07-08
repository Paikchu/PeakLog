# Phase 2 技术方案: LLM 周计划生成主链路

> 上承 ADR-001(`docs/architecture/adr-001-llm-weekly-plan-generation.md`)Phase 2;
> 前置 Phase 0(登录+同步)、Phase 1(GoalSpec / 编辑事件流 / plan_generations 溯源表)均已完成并提交。
> 定位:把"AI 在背后做事"真正跑起来——每周日晚,服务端读取用户的目标、本周实际训练与编辑事件,由 LLM 生成下一整周计划,经 Validator 钳制后写入云端,周一早晨用户打开 App 即见新计划与教练解说。

## 1. 范围

### 做

1. **共享纯函数层**(`backend/supabase/functions/_shared/`):ContextBuilder 统计、参考重量计算、Validator——全部可用 node --test 离线测试。
2. **`generate-weekly-plan` Edge Function**:装配上下文 → LLM(provider adapter)→ Validator + repair loop → 事务化写入计划 + 溯源;支持 `dry_run` 安全试跑。
3. **事务化安装 RPC**:`install_generated_plan(jsonb)` Postgres 函数,整周计划一次事务写入,杜绝半程写入。
4. **调度与轮换**:启用 pg_cron + pg_net,每小时唤醒,按用户本地时区判定"周日 20:00 后且下周计划不存在"才生成;旧周计划惰性归档。
5. **失败兜底**:LLM 彻底失败时生成"重复本周"的确定性 fallback 计划,保证用户永远有计划可练。
6. **客户端两处小改动**:计划拉取按日期选择(见 §4.2);登录后把设备时区回写云端(修复 C8)。

### 明确不做

- 不做周中动态重排(Phase 3:行为推断 + 一键输入触发)。
- 不做自由文本目标的 LLM 解析(Phase 3)。
- 不做指标看板(依从率/编辑率/进阶速度已在 context_snapshot 里留痕,看板另立项)。
- 不做教练周报独立 UI——本期的"教练解说"载体是 `coach_summary`(周级)+ `notes`(动作级),客户端现有字段直接显示。
- 不做多 LLM 投票/多候选评审(ADR 的质量升级路径,待有真实数据后评估)。

## 2. 总体架构与数据流

```
pg_cron (每小时 :05, UTC)
   │  pg_net POST + Vault 里的函数密钥
   ▼
generate-weekly-plan (Edge Function, service_role)
   │ 1. 选人: 遍历 profiles, 本地时间 ∈ 周日 20:00~次日, 且下周计划不存在
   │ 2. ContextBuilder(纯函数): 读云表 → 事实 JSON
   │     · GoalSpec(缺省则保守默认, C7)
   │     · 最近 4 周: 计划目标 vs 实际完成(linked sets), 依从率
   │     · 每动作: 达标情况、e1RM 趋势(Epley)、参考下一步重量(double progression)
   │     · 最近 14 天编辑事件流(source='user')
   │     · 动作库(随函数打包的 exercise_library.json ∪ 该用户 custom_exercises)
   │ 3. LLM adapter: system prompt(训练学+输出 schema) + 事实 JSON
   │     → 整周计划 JSON(7 天, 训练日带动作/组/目标, 休息日空)
   │ 4. Validator(纯函数): 动作名∈库、周负荷钳制≤110%实际、schema/天数校验
   │     · 可钳制的直接钳制并记 verdict; 不可钳的带违规项 repair 重试(≤2)
   │     · 终态失败 → fallback: 复制本周计划结构(engine='fallback_repeat')
   │ 5. install_generated_plan RPC: 单事务写 training_plan_* (下周, status='active')
   │     + 归档 week_start < 本周的旧 active 计划
   │ 6. 写 plan_generations: context_snapshot / raw_response / verdicts / 版本 / 状态
   ▼
客户端下次 pull: 按 week_start_date <= today 选当周计划(见 §4.2), 周一自动切换
```

关键性质:**生成写"下一周",不碰"当前周"**——用户周日晚还在执行的计划不受影响;新旧计划通过客户端的按日期选择自然交接,不需要"激活切换"这个额外状态机。

## 3. 服务端设计

### 3.1 共享纯函数(`_shared/*.mjs`,Deno 可直接 import,node --test 可直接测)

- **`referenceWeight.mjs`** — double progression 的确定性算术,输出进 context 供 LLM 采纳/推翻:
  - 该动作最近一次出现:全部组达到目标次数 → 建议加重(barbell/machine/cable +2.5kg,dumbbell/kettlebell +2kg,查库得 equipment);
  - 连续 2 次未达标 → 建议 -10% 重来;其余 → 保持;
  - `loadType == bodyweight` → 建议 +1~2 次数而非重量(C18);
  - 单位一律 kg 计算,按 `user_preferences.weight_unit` 输出显示单位(C19)。
- **`contextBuilder.mjs`** — 输入各表原始行,输出事实 JSON:依从率(计划组完成数/总数)、每动作达标明细、e1RM 序列、编辑事件摘要(原始事件 + 按类型计数)、GoalSpec、可用动作库(id/名称/肌群/器械/loadType 的精简投影,135 条 + custom)。**纯函数,不碰网络**。
- **`validator.mjs`** — 只做安全,不做策略:
  1. 每个动作 `exerciseId` 必须 ∈ 库(种子∪custom);未知 → repair 违规项;
  2. 每个动作最大目标重量 ≤ 该动作上周**实际**最大重量 × 1.10;超出 → **直接钳制**到上限并记 verdict(钳制是确定性安全编辑,不值得一次 LLM 往返);无历史的新动作 → 若有同名 e1RM 历史则钳 ≤ e1RM×0.9,否则放行(prompt 已要求保守起始);
  3. schema:恰好 7 天、plan_date 连续且从下周一开始、训练日数 == GoalSpec.daysPerWeek、每动作 ≥1 组、reps ∈ 1..30、weighted 动作必须有重量 / bodyweight 可空;
  4. 违规分级:可钳制的(2)就地修;结构性的(1/3)进 repair loop。
- **`prompt.mjs`** — system prompt(训练学:渐进超负荷、double progression、肌群周频率≥2 与恢复间隔、deload 意识、尊重 GoalSpec 的天数/时长/器械/部位/经验、解读编辑事件信号、输出 JSON schema、语言跟随用户 preferences.language)+ `PROMPT_VERSION = 'v1'` 常量。改 prompt 必须升版本号——溯源可比对。

### 3.2 LLM provider adapter(`_shared/llm.mjs`)

`generate(context, {provider, model}) -> {rawText, parsed}`。首发 **DeepSeek**(`deepseek-chat`,`response_format: json_object`,温度低);接口预留 Anthropic(`claude-sonnet-5`)——换 provider 只改 env(`LLM_PROVIDER`/`LLM_MODEL`),不改调用方。超时 60s、失败重试 1 次(C11);API key 从 Edge Function secrets 读。

### 3.3 `install_generated_plan(p_user_id uuid, p_plan jsonb)` RPC

单事务内:插入 training_plans(下周,`status='active'`)+ days/exercises/sets;同事务把该用户 `status='active'` 且 `week_start_date < 本周一` 的旧计划置 `archived`(惰性归档,C9 的自愈点)。幂等护栏:`idx_training_plans_active_week UNIQUE(user_id, week_start_date)` 已存在,重复安装直接失败被捕获(C5)。`SECURITY DEFINER`,仅 service_role 可执行(REVOKE from authenticated)。

**硬性不变量(C21,数据库级强制,不只是流程设计意图)**:用户明确要求——生成绝不能碰"正在进行的计划"(当前周)或"已完成的计划"(过去周)。RPC 入口第一步做强制校验,不满足直接 `RAISE EXCEPTION` 回滚整个事务:

```sql
-- p_plan->>'week_start_date' 必须严格晚于该用户当前周的周一
if (p_plan->>'week_start_date')::date <= v_current_week_monday then
  raise exception 'refusing to install a plan for the current or a past week (got %, current week is %)',
    p_plan->>'week_start_date', v_current_week_monday;
end if;
```

`v_current_week_monday` 按该用户 `profiles.timezone`(§4.1 回写后应已是真实时区)计算"现在"所在周的周一。这条校验独立于上游 Edge Function 的日期计算是否正确——即便调用方算错了目标周,数据库这一层也会硬拒绝,绝不会有任何写路径能触达当前周或历史周的 `training_plan_days/exercises/sets`(这些表本身也完全没有 UPDATE 语句,只有 INSERT——归档步骤只 `UPDATE training_plans.status`,不碰计划内容,不碰任何 `completed_at`/`linked_exercise_set_id` 执行数据)。

### 3.4 Edge Function 主体(`generate-weekly-plan/index.ts`)

- 鉴权:仅接受带 `x-generation-secret`(Vault 存储)的调用或 service_role JWT;普通用户 401(本期不开放客户端触发)。
- 请求参数:`{dry_run?: bool, user_id?: uuid, force?: bool}`——`dry_run` 走完整链路但**只写 plan_generations(status='draft'),不写计划表**(安全试跑的关键);`user_id` 定点触发(开发用);`force` 跳过"已存在下周计划"检查(配合先删,慎用)。
- 每用户流程失败互不影响;所有终态(成功/fallback/失败)都写 plan_generations 一行。

### 3.5 调度(migration 启用)

- `CREATE EXTENSION pg_cron; CREATE EXTENSION pg_net;`
- Vault 存函数 URL + generation secret;
- `cron.schedule('generate-weekly-plans', '5 * * * *', $$ select net.http_post(...) $$)`——每小时打一次函数,函数内部按用户时区判定是否到点(周日 20:00 ≤ 本地时间,且下周计划不存在 → 生成一次)。窗口宽(到点后每小时都有机会),配合幂等检查,漏一班车下一小时补上,不会重复生成。

## 4. 客户端改动(刻意最小)

### 4.1 时区回写(修 C8,**生成准时性的前置**)

现状:云端 `profiles.timezone = 'UTC'`(触发器默认值,客户端从未回写真实时区)。登录/回前台时若 `TimeZone.current.identifier ≠ preferences.timezone` 则更新本地偏好(走既有 mutation → 推送链路)。不做 UI。

### 4.2 计划拉取按日期选择

`CloudSnapshotLoader` 的 training_plans 查询从 `status=eq.active + order desc + limit 1` 改为追加 `week_start_date=lte.<今天>`——周日晚云端出现下周计划后,客户端在周日仍选中当前周,周一自然切换,无需激活状态机。子表 scoped 拉取(Phase 1 已建)自动跟随所选 plan_id。

**全程零 UI、零用户交互(用户明确要求)**:整条链路——生成触发(cron)、写入(RPC)、交付(客户端按日期自动选中新计划)——没有任何一步需要用户点击"生成计划"或做任何确认。用户体验只是:周一打开 App,Today 页自然显示的就是新的一周。§4.1/§4.2 两处改动都是纯后台数据层修改,不新增任何按钮、弹窗或提示;`coach_summary`/`notes` 复用现有字段展示,不新建 UI 组件。

### 4.3 已知可接受的行为(不改)

客户端 mapper 推送计划时 status 硬编码 `'active'`:轮换后若用户带着未推送的旧周改动打开 App,旧计划会被短暂重新置回 active——§3.3 的惰性归档每周自愈,且按日期选择保证 UI 永远显示正确的周(C9)。为省一个客户端模型字段,接受此项并记录。

## 5. 异常点与 Corner Case 清单

| # | 场景 | 处理 |
|---|---|---|
| C1 | 冷启动:无任何训练历史 | context 标注 `isColdStart`,prompt 要求保守起始重量(宁低勿高,让用户往上改——第一周的编辑事件正是最有价值的信号);coach_summary 说明这是起始周 |
| C2 | LLM 彻底失败(超时/连续 repair 失败/配额) | fallback:复制当前周计划结构与目标为下周(日期平移),`plan_generations.engine='fallback_repeat'`,coach_summary 如实说明;**用户永远有计划** |
| C3 | LLM 幻觉动作名 | Validator 按库(种子∪custom)拒绝 → repair loop(违规清单回喂)≤2 次 → 仍失败走 C2 |
| C4 | 周负荷跳涨 >110% | 直接钳制到上限 + 记 verdict,不做 LLM 往返(确定性安全编辑) |
| C5 | 重复生成(cron 重叠/手动重试) | 函数先查下周计划是否已存在;`UNIQUE(user_id, week_start_date)` 做 DB 级兜底 |
| C6 | 生成瞬间用户正在编辑当前周 | 生成只读快照、只写下一周,零冲突;用户的编辑照常进事件流,下下周吸收 |
| C7 | 无 GoalSpec | 用保守默认(general/3 天/60 分钟),coach_summary 提示补填(Phase 1 G5 的兑现) |
| C8 | **profiles.timezone 是 'UTC'(现状实测)** | §4.1 客户端回写设备时区;函数端 timezone 解析失败回退 UTC 并记日志 |
| C9 | 旧版客户端把已归档计划推回 active | 按日期选择保证显示正确;下次生成的惰性归档自愈;记录为已知行为 |
| C10 | 下周计划已存在时手动重跑 | 默认跳过;`force` 需显式传入,且只在 dry_run 验证后使用 |
| C11 | LLM 慢/贵 | 60s 超时 + 1 次重试;每用户每周 1 次调用 + repair ≤2,成本天然有界 |
| C12 | 函数打包的动作库与客户端 bundle 漂移 | 部署脚本从同一份 `PeakLog/Resources/exercise_library.json` 复制;Validator 对未知名走 repair 而非崩溃;库版本号写进 context_snapshot 便于排查 |
| C13 | 计划半程写入(部分表成功) | `install_generated_plan` 单事务,要么整周落库要么回滚 |
| C14 | 事件重复消费 | ContextBuilder 只读、按时间窗取,无标记消费概念,天然幂等 |
| C15 | LLM 输出的 JSON 解析失败/字段缺失 | 与 C3 同路径:violation 回喂 repair → C2 兜底 |
| C16 | Vault/secrets 缺失 | 函数启动即 fail-fast,写日志;cron 下一小时重试;不产生半程状态 |
| C17 | 用户连续数周零训练 | context 如实呈现;prompt 要求"回归周"处理(降量重启)而非线性加重——这是 prompt 策略,不写死规则 |
| C18 | 自重动作的"进阶" | 参考建议按次数 +1~2,不按重量;Validator 对 bodyweight 免重量校验 |
| C19 | 用户用 lbs 记录 | 上下文统一 kg 计算(沿用 e897cf6 的归一化口径),输出按偏好单位;钳制比较在 kg 域进行 |
| C20 | plan_generations 体积膨胀 | context_snapshot 只存投影后的事实 JSON(非原始行);单行 <100KB 量级,暂不设保留策略 |
| C21 | **生成误碰当前周/历史周(用户明确要求的硬约束)** | §3.3 的数据库级不变量:RPC 强制校验目标周严格晚于当前周,不满足直接回滚整个事务;归档步骤只改 `training_plans.status`,从不 UPDATE 计划内容或执行数据;必须有专门测试覆盖(§6-4) |

## 6. 测试与验证

**真实数据保护(延续硬规则)**:开发账号有真实训练数据。生成类测试一律先走 `dry_run`(不写计划表);首次真实安装用 `user_id` 定点 + 事后核查;绝不整表清除。

1. **node --test(`backend/tests/`,恢复该目录惯例)**:
   - `validator.test.mjs`:未知动作、>110% 钳制、天数不符、reps 越界、bodyweight 免重量、repair 违规清单格式;
   - `reference_weight.test.mjs`:全达标 +2.5/+2、连续失败 -10%、bodyweight +reps、lbs→kg;
   - `context_builder.test.mjs`:依从率、e1RM、事件摘要、冷启动标记。
2. **dry_run live 验证**:部署后对开发账号跑 `{dry_run: true, user_id: ...}` → 检查 plan_generations 的 context_snapshot(事实是否符合该账号真实数据)、raw_response(LLM 输出质量人工评审)、verdicts;**这一步同时是 prompt 调优的迭代环**,预期跑多轮。
3. **真实安装验证**:`{user_id, force?}` 生成下周计划 → SQL 核查 7 天/天数/钳制;客户端(§4.2 改动后)拉取确认周日仍显示当前周、模拟日期到周一后显示新周;当前周计划与训练数据分毫未动。
4. **失败路径**:临时坏 API key 触发 C2 → 确认 fallback 计划 + `engine='fallback_repeat'` + status 记录正确;重复触发确认 C5 幂等。
5. **客户端回归**:时区回写与拉取过滤两处改动的逻辑测试 + 全量 `xcodebuild test`。
6. **C21 硬约束专项验证(必做,不可省略)**:直接调用 `install_generated_plan` 并故意传入当前周/上周的 `week_start_date`,断言事务被拒绝、`RAISE EXCEPTION` 触发、`training_plans`/`_days`/`_exercises`/`_sets` 均无变化;并对已有 `completed_at`/`linked_exercise_set_id` 的真实组做写前/写后快照比对,确认逐字节不变。

## 7. 实施顺序(稳步推进,每步可独立验收)

1. [x] **纯函数层 + node 测试**:`_shared/` 四个模块 + `backend/tests/` 三个测试文件,全绿(零部署风险)
2. [x] **客户端两小改**:时区回写 + 拉取日期过滤(+逻辑测试、全量回归)——先行落地,不依赖服务端
3. [x] **RPC + migration**:`install_generated_plan` + 启用 pg_cron/pg_net + Vault 配置(先建不调度)
4. [x] **Edge Function 部署 + dry_run 迭代**:部署 `generate-weekly-plan`,对开发账号反复 dry_run,人工评审 LLM 输出直到满意(prompt v1 定稿)
5. [x] **首次真实生成**:定点触发 → 全面核查 → 客户端周一切换验证
6. [x] **接通 cron**:挂上每小时调度,观察一个完整周日晚的自动运行
7. [x] **失败演练 + 文档**:C2/C5 演练;工作日志、README/api-reference 增补

## 8. 用户已拍板的点(2026-07-08)

1. **LLM provider**:DeepSeek,用户自行在 Dashboard 配置 `DEEPSEEK_API_KEY`(Phase 2 实施不包含配置这把 key,§7 第 4 步部署后需要用户确认 key 已就位才能跑通真实 dry_run)。
2. **生成时机**:周日 20:00(用户本地时区)后第一个整点,确认可接受;**并追加硬约束**:生成绝不能调整正在进行(当前周)或已完成(历史周)的计划——已落地为 §3.3 的 C21 数据库级不变量,不是流程层面的君子协定。
3. **休息日形态**:空动作 + 标题,确认采纳。
4. **交付方式**:全程后台静默,零用户交互(不加"生成计划"按钮或任何前台确认步骤)——已在 §4.2 明确记录,§4.1/§4.2 两处客户端改动均为纯数据层修改。

按此方案开始实施,顺序见 §7。
