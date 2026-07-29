#!/usr/bin/env bash
# migration-ledger-audit —— 仓库 migration ledger 与线上 ledger 的**只读**对账。
#
# 背景（Issue #131）：`supabase migration list --linked` 显示大量版本只存在于
# 一边。原因是一部分迁移当初是通过 MCP `apply_migration` 打进生产的——MCP 用
# 调用当刻的 UTC 时间戳记账，而仓库里的文件用的是人工编的顺序号
# （20260707000009 这种），于是同一份 SQL 在两边留下两个不同 version。
# 光看版本号列表无法区分「这份 SQL 换了个时间戳跑过」和「这份 SQL 真的没跑
# 过」，而这两者的修复动作完全相反（repair vs push）。本脚本把两边的**真实
# SQL 正文**都拉下来做同名配对 + 逐行 diff，让判定有据可依。
#
# 本脚本严格只读，不会执行任何写操作：
#   - `supabase migration list --linked`     读 ledger
#   - `supabase migration fetch --linked`    读 ledger 里存的 SQL 正文
#     （--workdir 指向输出目录下的一次性镜像工程，绝不写进 backend/supabase/migrations）
# 不调用 db push / migration repair / db reset --linked。
#
# 用法：
#   backend/scripts/migration-ledger-audit.sh [--out <dir>] [--project-ref <ref>] [--offline] [--allow-drift]
#
# 退出码：
#   0  对账完成且无分叉（或 --allow-drift）
#   1  存在 local-only / remote-only 版本
#   2  参数错误
#   3  缺少凭据或无法连接线上（**不当作通过**，CI 应据此 skip 而不是绿灯）

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BACKEND_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
MIGRATIONS_DIR="${BACKEND_DIR}/supabase/migrations"

OUT_DIR=""
PROJECT_REF="${SUPABASE_PROJECT_REF:-}"
OFFLINE=0
ALLOW_DRIFT=0

usage() {
  cat <<'USAGE'
migration-ledger-audit —— 仓库与线上 migration ledger 的只读对账

用法：
  backend/scripts/migration-ledger-audit.sh [选项]

选项：
  --out <dir>          输出目录（默认 $TMPDIR/peaklog-migration-ledger-<时间戳>）
  --project-ref <ref>  线上项目 ref；默认取 SUPABASE_PROJECT_REF，
                       再退回 backend/supabase/.temp/project-ref（supabase link 产物）
  --offline            只生成本地清单和「该跑哪些命令」的说明，不连线上
  --allow-drift        发现分叉时仍然返回 0（生成报告用，CI 请勿使用）
  -h, --help           显示本帮助

产出（<out> 目录下）：
  local-ledger.tsv      仓库内迁移：version / 文件名 / 是否自称经 MCP 应用 / 首行注释
  remote-ledger.tsv     线上 ledger：version / name        （--offline 时为空壳）
  migration-list.txt    `supabase migration list --linked` 原样输出（对账前快照）
  remote-mirror/        线上 ledger 里存的 SQL 正文（一次性镜像工程）
  diffs/<version>.diff  同名配对后的正文差异
  ledger-report.md      判定结论汇总

退出码：0 无分叉 / 1 有分叉 / 2 参数错误 / 3 缺凭据（不是通过）
USAGE
}

while [ $# -gt 0 ]; do
  case "$1" in
    --out) OUT_DIR="${2:-}"; [ -n "$OUT_DIR" ] || { echo "--out 需要一个目录参数" >&2; exit 2; }; shift 2 ;;
    --project-ref) PROJECT_REF="${2:-}"; [ -n "$PROJECT_REF" ] || { echo "--project-ref 需要一个值" >&2; exit 2; }; shift 2 ;;
    --offline) OFFLINE=1; shift ;;
    --allow-drift) ALLOW_DRIFT=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "未知参数：$1" >&2; usage >&2; exit 2 ;;
  esac
done

if [ ! -d "$MIGRATIONS_DIR" ]; then
  echo "找不到迁移目录：$MIGRATIONS_DIR" >&2
  exit 2
fi

if [ -z "$OUT_DIR" ]; then
  OUT_DIR="${TMPDIR:-/tmp}/peaklog-migration-ledger-$(date -u +%Y%m%dT%H%M%SZ)"
fi
mkdir -p "$OUT_DIR/diffs"

LOCAL_LEDGER="$OUT_DIR/local-ledger.tsv"
REMOTE_LEDGER="$OUT_DIR/remote-ledger.tsv"
LIST_RAW="$OUT_DIR/migration-list.txt"
MIRROR="$OUT_DIR/remote-mirror"
REPORT="$OUT_DIR/ledger-report.md"

# ---------------------------------------------------------------------------
# 1. 本地清单（无需凭据，任何情况下都产出）
# ---------------------------------------------------------------------------
# 「是否自称经 MCP 应用」这一列是关键线索：写了这句话的文件几乎必然对应线上
# 某个不同时间戳的 version，属于 repair 候选而不是 push 候选。
printf 'version\tfile\tapplied_via_mcp\tsummary\n' > "$LOCAL_LEDGER"
for path in "$MIGRATIONS_DIR"/*.sql; do
  [ -e "$path" ] || continue
  file="$(basename "$path")"
  version="${file%%_*}"
  if grep -qiE '^--.*via MCP' "$path"; then
    mcp='yes'
  else
    mcp='no'
  fi
  # 取第一条有实质内容的注释行作为一句话作用说明；纯分隔线（---- / ====）跳过。
  summary="$(grep -m1 -E '^--[[:space:]]*[^-=[:space:]]' "$path" | sed -E 's/^--[[:space:]]*//' | cut -c1-110 || true)"
  [ -n "$summary" ] || summary='(无文件头注释)'
  printf '%s\t%s\t%s\t%s\n' "$version" "$file" "$mcp" "$summary" >> "$LOCAL_LEDGER"
done
LOCAL_COUNT="$(( $(wc -l < "$LOCAL_LEDGER") - 1 ))"
echo "本地迁移清单已写入：$LOCAL_LEDGER（${LOCAL_COUNT} 份）"

collect_commands() {
  cat <<COMMANDS
需要用户带凭据补齐的采集命令（全部只读）：

  cd backend
  supabase link --project-ref ${PROJECT_REF:-<project-ref>}      # 只写本地 .temp，不改线上
  supabase migration list --linked | tee "$LIST_RAW"
  mkdir -p "$MIRROR/supabase/migrations" "$MIRROR/supabase/.temp"
  printf 'project_id = "peaklog-remote-mirror"\n' > "$MIRROR/supabase/config.toml"
  printf '%s' "${PROJECT_REF:-<project-ref>}" > "$MIRROR/supabase/.temp/project-ref"
  supabase migration fetch --linked --workdir "$MIRROR"
  supabase db dump --linked -f "$OUT_DIR/prod-schema.sql"        # 对账前 schema 快照

采集完成后重跑本脚本即可生成完整报告。
COMMANDS
}

write_offline_report() {
  local reason="$1"
  {
    printf '# Migration ledger 对账报告\n\n'
    printf -- '- 生成时间（UTC）：%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    printf -- '- 仓库迁移数：%s\n' "$LOCAL_COUNT"
    printf -- '- 线上 ledger：**未采集**（%s）\n\n' "$reason"
    printf '## 远端 ledger（待补齐）\n\n'
    printf '| version | name | 与本地同名文件 | 判定 |\n|---|---|---|---|\n'
    printf '| _未采集_ | _未采集_ | _未采集_ | _未采集_ |\n\n'
    printf '%s\n' '```'
    collect_commands
    printf '%s\n' '```'
  } > "$REPORT"
  printf 'version\tname\n' > "$REMOTE_LEDGER"
  echo "报告已写入：$REPORT（远端部分标记为未采集）"
}

if [ "$OFFLINE" -eq 1 ]; then
  write_offline_report '本次以 --offline 运行'
  exit 3
fi

# ---------------------------------------------------------------------------
# 2. 凭据与连通性探测
# ---------------------------------------------------------------------------
if ! command -v supabase >/dev/null 2>&1; then
  write_offline_report '未安装 supabase CLI'
  echo "缺少 supabase CLI，无法对账（退出码 3，不代表通过）" >&2
  exit 3
fi

if [ -z "$PROJECT_REF" ] && [ -f "${BACKEND_DIR}/supabase/.temp/project-ref" ]; then
  PROJECT_REF="$(cat "${BACKEND_DIR}/supabase/.temp/project-ref")"
fi
if [ -z "$PROJECT_REF" ]; then
  write_offline_report '未提供 project ref（既无 --project-ref/SUPABASE_PROJECT_REF，也没有 supabase link 产物）'
  echo "缺少 project ref，无法对账（退出码 3，不代表通过）" >&2
  exit 3
fi

# CLI 的 --linked 会去读 backend/supabase/.temp/project-ref，所以在 CI 这种
# 没跑过 supabase link 的环境里先把它补上。这只写本地文件，不触碰线上。
mkdir -p "${BACKEND_DIR}/supabase/.temp"
printf '%s' "$PROJECT_REF" > "${BACKEND_DIR}/supabase/.temp/project-ref"

if ! (cd "$BACKEND_DIR" && supabase migration list --linked) > "$LIST_RAW" 2>"$OUT_DIR/migration-list.err"; then
  write_offline_report "无法连接线上项目 $PROJECT_REF（详见 $OUT_DIR/migration-list.err）"
  echo "连接线上失败，无法对账（退出码 3，不代表通过）：" >&2
  tail -n 20 "$OUT_DIR/migration-list.err" >&2 || true
  exit 3
fi
echo "线上 ledger 快照已写入：$LIST_RAW"

# ---------------------------------------------------------------------------
# 3. 解析 `migration list` 的两列，得到 local-only / remote-only / common
# ---------------------------------------------------------------------------
# 输出形如 `   20260318000001 | 20260318000001 | 2026-03-18 00:00:01 `，
# 单边缺失时对应列为空。用 awk 按 | 切列并去空白，比正则整行匹配更耐版本变化。
awk -F'|' '
  /^[[:space:]]*[0-9]{14}[[:space:]]*\|/ || /^[[:space:]]*\|[[:space:]]*[0-9]{14}/ {
    l = $1; r = $2
    gsub(/[[:space:]]/, "", l); gsub(/[[:space:]]/, "", r)
    print l "\t" r
  }
' "$LIST_RAW" > "$OUT_DIR/ledger-pairs.tsv"

cut -f1 "$OUT_DIR/ledger-pairs.tsv" | grep -E '^[0-9]{14}$' | sort -u > "$OUT_DIR/.local-versions"
cut -f2 "$OUT_DIR/ledger-pairs.tsv" | grep -E '^[0-9]{14}$' | sort -u > "$OUT_DIR/.remote-versions"
comm -23 "$OUT_DIR/.local-versions" "$OUT_DIR/.remote-versions" > "$OUT_DIR/.local-only"
comm -13 "$OUT_DIR/.local-versions" "$OUT_DIR/.remote-versions" > "$OUT_DIR/.remote-only"
comm -12 "$OUT_DIR/.local-versions" "$OUT_DIR/.remote-versions" > "$OUT_DIR/.common"

LOCAL_ONLY_COUNT="$(wc -l < "$OUT_DIR/.local-only" | tr -d ' ')"
REMOTE_ONLY_COUNT="$(wc -l < "$OUT_DIR/.remote-only" | tr -d ' ')"
COMMON_COUNT="$(wc -l < "$OUT_DIR/.common" | tr -d ' ')"

# ---------------------------------------------------------------------------
# 4. 拉取线上 ledger 里存的 SQL 正文（只读），做同名配对 diff
# ---------------------------------------------------------------------------
# `supabase migration fetch` 会把正文写进 <workdir>/supabase/migrations。这里
# 用一个一次性镜像工程当 workdir，**绝不能**指向 backend——那会往仓库里塞进
# 未经审计的迁移文件，正是 issue 明令禁止的「伪造未核对内容」。
rm -rf "$MIRROR"
mkdir -p "$MIRROR/supabase/migrations" "$MIRROR/supabase/.temp"
printf 'project_id = "peaklog-remote-mirror"\n' > "$MIRROR/supabase/config.toml"
printf '%s' "$PROJECT_REF" > "$MIRROR/supabase/.temp/project-ref"
if ! supabase migration fetch --linked --workdir "$MIRROR" >"$OUT_DIR/migration-fetch.log" 2>&1; then
  echo "supabase migration fetch 失败，正文对比将跳过（详见 $OUT_DIR/migration-fetch.log）" >&2
fi

printf 'version\tname\n' > "$REMOTE_LEDGER"
for path in "$MIRROR/supabase/migrations"/*.sql; do
  [ -e "$path" ] || continue
  file="$(basename "$path")"
  version="${file%%_*}"
  name="${file#*_}"
  printf '%s\t%s\n' "$version" "${name%.sql}" >> "$REMOTE_LEDGER"
done

# 正文归一化：去掉注释行、空行和行尾空白后再比。注释在两边天然不同（仓库文件
# 有中文说明头，MCP 记账时存的是提交给数据库的正文），拿原文比会全是噪声；
# 但归一化只用于「值不值得人工细看」的分级，最终判定仍以完整 diff 为准。
#
# 另外要抹平一个纯记账伪影：ledger 把每份迁移按 statement 数组存，
# `supabase migration fetch` 重建文件时会给每条语句补一个 `;` 分隔符，于是
# 原本就以 `;` 结尾的语句变成 `;;`、整块 DO 语句后多出一行孤立的 `;`。这是
# CLI 的序列化差异而不是 SQL 差异，不抹平的话每一对都会被判成 DIVERGED，
# 真正需要人工细看的那几份就会淹没在噪声里。
normalize() {
  sed -E 's/[[:space:]]+$//; s/;;+$/;/' "$1" \
    | grep -vE '^[[:space:]]*--' \
    | grep -vE '^[[:space:]]*$' \
    | grep -vE '^[[:space:]]*;[[:space:]]*$'
}

classify_pair() {
  # $1 = remote sql path, $2 = local sql path, $3 = diff 输出路径
  if diff -u <(normalize "$2") <(normalize "$1") > "$3"; then
    echo 'IDENTICAL'
  else
    echo 'DIVERGED'
  fi
}

{
  printf '# Migration ledger 对账报告\n\n'
  printf -- '- 生成时间（UTC）：%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  printf -- '- 线上项目 ref：`%s`\n' "$PROJECT_REF"
  printf -- '- 仓库迁移数：%s；线上 ledger 版本数：%s\n' "$LOCAL_COUNT" "$(( $(wc -l < "$REMOTE_LEDGER") - 1 ))"
  printf -- '- 两边一致：%s；仅本地：%s；仅远端：%s\n\n' "$COMMON_COUNT" "$LOCAL_ONLY_COUNT" "$REMOTE_ONLY_COUNT"

  printf '## 判定表\n\n'
  printf '| 类别 | 本地 version | 远端 version | 迁移名 | 正文比对 | 建议动作 |\n'
  printf '|---|---|---|---|---|---|\n'

  while read -r rv; do
    [ -n "$rv" ] || continue
    rpath="$(ls "$MIRROR/supabase/migrations/${rv}_"*.sql 2>/dev/null | head -1 || true)"
    [ -n "$rpath" ] || { printf '| remote-only | — | `%s` | _正文未取到_ | n/a | 人工确认 |\n' "$rv"; continue; }
    rname="$(basename "$rpath")"; rname="${rname#*_}"; rname="${rname%.sql}"
    lpath="$(ls "$MIGRATIONS_DIR"/*_"${rname}".sql 2>/dev/null | head -1 || true)"
    if [ -z "$lpath" ]; then
      printf '| remote-only（仓库无同名文件） | — | `%s` | `%s` | n/a | 审计正文后**新增**一份等价迁移文件再 repair applied |\n' "$rv" "$rname"
      cp "$rpath" "$OUT_DIR/diffs/${rv}_${rname}.remote.sql"
      continue
    fi
    lv="$(basename "$lpath")"; lv="${lv%%_*}"
    verdict="$(classify_pair "$rpath" "$lpath" "$OUT_DIR/diffs/${rv}.diff")"
    if [ "$verdict" = 'IDENTICAL' ]; then
      action='同一份 SQL 换了时间戳跑过 → repair：本地 applied + 远端 reverted'
    else
      action='同名但正文不同 → 逐行审计 diff 后再决定 repair 还是补新迁移'
    fi
    printf '| 时间戳错位 | `%s` | `%s` | `%s` | %s | %s |\n' "$lv" "$rv" "$rname" "$verdict" "$action"
  done < "$OUT_DIR/.remote-only"

  while read -r lv; do
    [ -n "$lv" ] || continue
    lpath="$(ls "$MIGRATIONS_DIR/${lv}_"*.sql 2>/dev/null | head -1 || true)"
    [ -n "$lpath" ] || continue
    lname="$(basename "$lpath")"; lname="${lname#*_}"; lname="${lname%.sql}"
    if ls "$MIRROR/supabase/migrations"/*_"${lname}".sql >/dev/null 2>&1; then
      continue  # 已在上面的 remote-only 循环里作为「时间戳错位」配对过
    fi
    printf '| local-only（线上无同名） | `%s` | — | `%s` | n/a | 线上很可能真的没跑过 → 核对 schema 实际对象后 `supabase db push` |\n' "$lv" "$lname"
  done < "$OUT_DIR/.local-only"

  printf '\n## 说明\n\n'
  printf -- '- `IDENTICAL` / `DIVERGED` 只是归一化（去注释、去空行）后的粗判，用于分级，**不能替代人工走读** `diffs/` 下的完整 diff。\n'
  printf -- '- 线上正文取自 `supabase_migrations.schema_migrations.statements`，即数据库自己记账的内容，不是推测。\n'
  printf -- '- repair 的具体执行顺序、备份要求和审批边界见 `docs/architecture/supabase-migration-ledger-repair.md`。\n'
} > "$REPORT"

echo "对账报告已写入：$REPORT"
echo "  一致 ${COMMON_COUNT} / 仅本地 ${LOCAL_ONLY_COUNT} / 仅远端 ${REMOTE_ONLY_COUNT}"

if [ "$LOCAL_ONLY_COUNT" -eq 0 ] && [ "$REMOTE_ONLY_COUNT" -eq 0 ]; then
  echo "ledger 已对齐。"
  exit 0
fi

if [ "$ALLOW_DRIFT" -eq 1 ]; then
  echo "检测到 ledger 分叉，但 --allow-drift 已启用，返回 0。"
  exit 0
fi

echo "检测到 ledger 分叉：local-only=${LOCAL_ONLY_COUNT}，remote-only=${REMOTE_ONLY_COUNT}" >&2
exit 1
