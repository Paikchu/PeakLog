#!/usr/bin/env bash
# migration-ledger-replay —— 在**本地 Supabase 容器**上从零 replay 仓库全部迁移，
# dump schema，并（可选）与生产 schema dump 做差异比对。
#
# 背景（Issue #131）：验收标准之一是「干净数据库完整 replay 后 schema、RLS、
# functions 与生产预期一致」。ledger 对齐（repair）只让两边的**版本号列表**
# 相同，并不能证明「按仓库文件重放一遍能得到生产那套对象」——历史上有过
# MCP 直接改库、也有过只存在于线上的 grant 修复，这些都不会体现在版本号上。
# 所以 repair 之后必须再跑一次真正的 replay 并逐行比 schema，才算闭环。
#
# 安全边界：本脚本只操作 `--local`（Docker 里的一次性 Postgres）。
# 生产 schema 由调用方**自己**用 `supabase db dump --linked -f <file>` 导出后
# 通过 --baseline 传进来，脚本不会主动连线上，也不会执行 db push / repair /
# db reset --linked。这样即使脚本被误用，最坏后果也只是重置本地容器。
#
# 用法：
#   backend/scripts/migration-ledger-replay.sh [--out <dir>] [--baseline <prod-schema.sql>]
#   backend/scripts/migration-ledger-replay.sh --skip-replay --replayed <a.sql> --baseline <b.sql>
#
# 退出码：
#   0  replay 成功；给了 --baseline 时表示归一化后无差异
#   1  与 baseline 存在 schema 差异
#   2  参数错误
#   3  环境不满足（缺 supabase CLI / Docker 未运行），**不是通过**
#   4  replay 本身失败（迁移在干净库上跑不通——这本身就是重大发现）

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BACKEND_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
MIGRATIONS_DIR="${BACKEND_DIR}/supabase/migrations"

OUT_DIR=""
BASELINE=""
REPLAYED_IN=""
SKIP_REPLAY=0
DRY_RUN=0
KEEP_RUNNING=0
# 默认空 = 不给 `supabase db dump` 传 --schema，用 CLI 自己的默认值。
# 这条默认值是有代价换来的：第一版默认 `public`，而 baseline 是用不带 --schema 的
# `supabase db dump --linked` 导的，两边 dump 口径不同 —— 加了 --schema 的一侧会丢掉
# CREATE EXTENSION 段和 extension 自带对象（如 moddatetime）的 GRANT，于是比对结果里
# 混进十几行纯属参数差异的噪声，真正的差异被掩盖。两侧必须用**同一组** dump 参数，
# 否则这个脚本给出的「一致 / 不一致」没有意义。
SCHEMAS=""

usage() {
  cat <<'USAGE'
migration-ledger-replay —— 本地干净 replay + schema dump + 与生产 dump 比对

用法：
  backend/scripts/migration-ledger-replay.sh [选项]

选项：
  --out <dir>          输出目录（默认 $TMPDIR/peaklog-migration-replay-<时间戳>）
  --baseline <file>    生产 schema dump 文件路径；由调用方自行导出：
                         supabase db dump --linked -f prod-schema.sql
                       脚本不会自己连线上。**导 baseline 时用的 --schema 参数
                       必须与下面 --schemas 一致**，否则比对结果没有意义。
  --replayed <file>    已有的 replay 后 dump，配合 --skip-replay 只做比对
  --skip-replay        跳过 replay，仅比对 --replayed 与 --baseline
  --schemas <list>     dump 的 schema 列表，逗号分隔；默认不传 --schema，
                       与不带参数的 `supabase db dump --linked` 口径对齐
  --keep-running       结束后保留本地 Supabase 容器（默认保留，占位以示显式）
  --dry-run            只打印将要执行的步骤并校验参数，不碰 Docker
  -h, --help           显示本帮助

产出（<out> 目录下）：
  replayed-schema.sql       干净 replay 后的本地 schema dump
  schema-diff.txt           与 baseline 归一化后的差异（给了 --baseline 时）
  replay.log                supabase db reset 的完整输出

退出码：0 一致 / 1 有差异 / 2 参数错误 / 3 环境不满足（不是通过）/ 4 replay 失败
USAGE
}

while [ $# -gt 0 ]; do
  case "$1" in
    --out) OUT_DIR="${2:-}"; [ -n "$OUT_DIR" ] || { echo "--out 需要一个目录参数" >&2; exit 2; }; shift 2 ;;
    --baseline) BASELINE="${2:-}"; [ -n "$BASELINE" ] || { echo "--baseline 需要一个文件路径" >&2; exit 2; }; shift 2 ;;
    --replayed) REPLAYED_IN="${2:-}"; [ -n "$REPLAYED_IN" ] || { echo "--replayed 需要一个文件路径" >&2; exit 2; }; shift 2 ;;
    --skip-replay) SKIP_REPLAY=1; shift ;;
    --schemas) SCHEMAS="${2:-}"; [ -n "$SCHEMAS" ] || { echo "--schemas 需要一个值" >&2; exit 2; }; shift 2 ;;
    --keep-running) KEEP_RUNNING=1; shift ;;
    --dry-run) DRY_RUN=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "未知参数：$1" >&2; usage >&2; exit 2 ;;
  esac
done

if [ ! -d "$MIGRATIONS_DIR" ]; then
  echo "找不到迁移目录：$MIGRATIONS_DIR" >&2
  exit 2
fi

if [ -n "$BASELINE" ] && [ ! -f "$BASELINE" ]; then
  echo "--baseline 指向的文件不存在：$BASELINE" >&2
  echo "先导出生产 schema（只读）：cd backend && supabase db dump --linked -f <file>" >&2
  exit 2
fi

if [ "$SKIP_REPLAY" -eq 1 ]; then
  if [ -z "$REPLAYED_IN" ] || [ -z "$BASELINE" ]; then
    echo "--skip-replay 需要同时提供 --replayed 和 --baseline" >&2
    exit 2
  fi
  if [ ! -f "$REPLAYED_IN" ]; then
    echo "--replayed 指向的文件不存在：$REPLAYED_IN" >&2
    exit 2
  fi
fi

if [ -z "$OUT_DIR" ]; then
  OUT_DIR="${TMPDIR:-/tmp}/peaklog-migration-replay-$(date -u +%Y%m%dT%H%M%SZ)"
fi
mkdir -p "$OUT_DIR"

REPLAYED="$OUT_DIR/replayed-schema.sql"
[ "$SKIP_REPLAY" -eq 1 ] && REPLAYED="$REPLAYED_IN"
DIFF_OUT="$OUT_DIR/schema-diff.txt"
REPLAY_LOG="$OUT_DIR/replay.log"

MIGRATION_COUNT="$(ls -1 "$MIGRATIONS_DIR"/*.sql 2>/dev/null | wc -l | tr -d ' ')"

if [ "$DRY_RUN" -eq 1 ]; then
  cat <<PLAN
[dry-run] 将执行的步骤：
  1. 校验 supabase CLI 与 Docker daemon 可用
  2. cd $BACKEND_DIR && supabase start                 # 仅本地容器
  3. supabase db reset --local --no-seed               # 从零 replay ${MIGRATION_COUNT} 份迁移
  4. supabase db dump --local${SCHEMAS:+ --schema $SCHEMAS} -f $REPLAYED
$(if [ -n "$BASELINE" ]; then echo "  5. 归一化后 diff：$BASELINE  <->  $REPLAYED  → $DIFF_OUT"; else echo "  5. （未提供 --baseline，跳过比对）"; fi)

[dry-run] baseline 必须用**同一组** dump 参数导出，否则比的是参数差异而非 schema 差异：
          cd backend && supabase db dump --linked${SCHEMAS:+ --schema $SCHEMAS} -f prod-schema.sql

[dry-run] 不会执行的动作：supabase db push / migration repair / db reset --linked /
          任何针对线上项目的写操作。生产 schema 只能由调用方用
          \`supabase db dump --linked\` 自行导出后经 --baseline 传入。
PLAN
  exit 0
fi

# ---------------------------------------------------------------------------
# 归一化 + 比对
# ---------------------------------------------------------------------------
# pg_dump 的输出里有几类**必然**不同、且与「schema 是否一致」无关的行：
#   - `-- Dumped from database version ...` 之类的版本横幅
#   - psql 15+ 的 \restrict / \unrestrict 保护指令（带随机 token）
#   - SET / SELECT pg_catalog.set_config(...) 会话前导
#   - 属主：托管环境是 supabase_admin，本地容器是 postgres
# 不抹平这些，任何一次比对都会输出上百行噪声，人就不会再看它了。
# 抹平范围刻意保守：只动上述几类，对象定义、RLS policy、GRANT 一律原样保留。
#
# 注意 OWNER 被整体归一成 <owner>：托管库和本地容器的超级用户名字天生不同，
# 这条差异永远存在且无法通过迁移消除，所以**属主正确性不在本比对的覆盖范围
# 内**，需要单独用 `\dp` / pg_proc.proacl 核对。这是刻意的取舍，不是遗漏。
normalize_dump() {
  sed -E \
    -e 's/[[:space:]]+$//' \
    -e 's/ OWNER TO [A-Za-z_][A-Za-z0-9_]*;/ OWNER TO <owner>;/' \
    "$1" \
    | grep -vE '^[[:space:]]*--' \
    | grep -vE '^\\(un)?restrict' \
    | grep -vE '^SET [a-z_]+ =' \
    | grep -vE '^SELECT pg_catalog\.set_config' \
    | grep -vE '^[[:space:]]*$'
}

compare_with_baseline() {
  if diff -u <(normalize_dump "$BASELINE") <(normalize_dump "$REPLAYED") > "$DIFF_OUT"; then
    echo "schema 比对：归一化后无差异（baseline=$BASELINE）"
    return 0
  fi
  echo "schema 比对：存在差异，详见 $DIFF_OUT"
  echo "  差异行数：$(wc -l < "$DIFF_OUT" | tr -d ' ')"
  return 1
}

if [ "$SKIP_REPLAY" -eq 1 ]; then
  echo "跳过 replay，仅比对已有 dump。"
  if compare_with_baseline; then exit 0; else exit 1; fi
fi

# ---------------------------------------------------------------------------
# 环境探测
# ---------------------------------------------------------------------------
if ! command -v supabase >/dev/null 2>&1; then
  echo "缺少 supabase CLI，无法 replay（退出码 3，不代表通过）" >&2
  exit 3
fi
if ! command -v docker >/dev/null 2>&1; then
  echo "缺少 docker，无法启动本地 Supabase（退出码 3，不代表通过）" >&2
  exit 3
fi
if ! docker info >/dev/null 2>&1; then
  echo "Docker daemon 未运行，无法启动本地 Supabase（退出码 3，不代表通过）" >&2
  echo "  macOS：先启动 Docker Desktop，或 \`open -a Docker\` 后等待就绪再重试。" >&2
  exit 3
fi

# ---------------------------------------------------------------------------
# 干净 replay
# ---------------------------------------------------------------------------
echo "启动本地 Supabase（仅容器，不触碰线上）…"
if ! (cd "$BACKEND_DIR" && supabase start) >"$REPLAY_LOG" 2>&1; then
  echo "supabase start 失败，详见 $REPLAY_LOG" >&2
  tail -n 30 "$REPLAY_LOG" >&2 || true
  exit 3
fi

echo "从零 replay ${MIGRATION_COUNT} 份迁移（supabase db reset --local）…"
# --no-seed：seed 数据不是 schema 的一部分，掺进来只会污染 dump 比对。
if ! (cd "$BACKEND_DIR" && supabase db reset --local --no-seed) >>"$REPLAY_LOG" 2>&1; then
  echo "replay 失败：仓库迁移在干净库上跑不通，详见 $REPLAY_LOG" >&2
  tail -n 40 "$REPLAY_LOG" >&2 || true
  exit 4
fi
echo "replay 成功，日志：$REPLAY_LOG"

echo "导出 replay 后的 schema（schemas=${SCHEMAS:-<CLI 默认>}）…"
# shellcheck disable=SC2086 -- SCHEMAS 为空时必须整体省略 --schema，不能传空串
if ! (cd "$BACKEND_DIR" && supabase db dump --local ${SCHEMAS:+--schema "$SCHEMAS"} -f "$REPLAYED") >>"$REPLAY_LOG" 2>&1; then
  echo "supabase db dump --local 失败，详见 $REPLAY_LOG" >&2
  exit 4
fi
echo "已写入：$REPLAYED"

if [ "$KEEP_RUNNING" -eq 0 ]; then
  # 默认不 stop：本地栈重启一次要几十秒，连续跑对账/replay 时保持常驻更省时间。
  # 需要释放资源时手动 `cd backend && supabase stop`。
  echo "本地 Supabase 保持运行；如需停止：cd backend && supabase stop"
fi

if [ -z "$BASELINE" ]; then
  echo "未提供 --baseline，跳过与生产 schema 的比对。"
  echo "  导出生产 schema（只读）：cd backend && supabase db dump --linked -f prod-schema.sql"
  exit 0
fi

if compare_with_baseline; then exit 0; else exit 1; fi
