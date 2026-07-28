#!/usr/bin/env node
// migration-ledger-check —— 仓库内迁移文件的静态自检，**不需要任何凭据**。
//
// 为什么单独有这么一个不联网的检查：Issue #131 的根因是 ledger（migration
// 历史表）与仓库分叉，而分叉的前置条件之一是「版本号可以随手写」。CI 里对
// 线上的对账依赖 Supabase secret，fork PR 和外部贡献者拿不到，那部分只能
// skip；但下面这些不变量纯靠 checkout 就能验证，必须**无条件**跑，否则一个
// 时间戳写错、重复或倒序的迁移能一路合进 main，等到部署时才炸。
//
// 检查项（任何一项失败 → exit 1）：
//   1. 文件名格式必须是 <14 位 UTC 时间戳>_<snake_case 名字>.sql，
//      这是 Supabase CLI 解析 version 的唯一依据（CLI 只取前 14 位数字）。
//   2. 版本号必须是合法的 UTC 时间戳（YYYYMMDDHHMMSS），避免 20261332...
//      这种月份 13 的手写值——它排序上仍然「递增」，但和线上 CLI 生成的
//      真实时间戳混在一起时无法判断先后。
//   3. 版本号不得重复：migration 历史表的主键就是 version，重复版本会让
//      「哪份 SQL 跑过」永久无法回答。
//   4. 版本号必须严格递增（等价于：按文件名字典序 == 按版本号数值序）。
//      CLI 按字典序执行，一旦出现倒序，本地 replay 顺序和线上真实执行顺序
//      就不一致，正是 #131 里 20260711000017 / 20260711100944 这类
//      「人工时间戳」与「CLI 时间戳」交错的产物。
//
// 用法：
//   node backend/scripts/migration-ledger-check.mjs [--dir <migrations 目录>] [--json]
//
// 退出码：0 = 全部通过；1 = 存在违规；2 = 参数或环境错误。

import { readdirSync, statSync } from 'node:fs';
import { resolve, dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

const HERE = dirname(fileURLToPath(import.meta.url));
const DEFAULT_DIR = resolve(HERE, '..', 'supabase', 'migrations');

// CLI 只认「前 14 位数字 + 下划线 + 名字」。名字部分限制成 snake_case 是仓库
// 自己的约定（现存 22 份迁移全部符合），保持一致才能让 remote-only 迁移按
// 名字和本地文件配对——对账脚本正是靠同名来判断「同一份 SQL 换了时间戳」。
const FILENAME_RE = /^(\d{14})_([a-z0-9]+(?:_[a-z0-9]+)*)\.sql$/;

function parseArgs(argv) {
  const opts = { dir: DEFAULT_DIR, json: false };
  for (let i = 0; i < argv.length; i += 1) {
    const arg = argv[i];
    if (arg === '--help' || arg === '-h') {
      opts.help = true;
    } else if (arg === '--json') {
      opts.json = true;
    } else if (arg === '--dir') {
      const value = argv[i + 1];
      if (!value) throw new Error('--dir 需要一个目录参数');
      opts.dir = resolve(value);
      i += 1;
    } else {
      throw new Error(`未知参数：${arg}`);
    }
  }
  return opts;
}

const USAGE = `migration-ledger-check —— 仓库内迁移文件静态自检（无需凭据）

用法：
  node backend/scripts/migration-ledger-check.mjs [选项]

选项：
  --dir <path>   迁移目录，默认 backend/supabase/migrations
  --json         以 JSON 输出结果，供 CI 二次消费
  -h, --help     显示本帮助

退出码：0 通过 / 1 发现违规 / 2 参数或环境错误
`;

/** 把 14 位版本号当作 UTC 时间戳解析；非法返回 null。 */
function parseVersionTimestamp(version) {
  const year = Number(version.slice(0, 4));
  const month = Number(version.slice(4, 6));
  const day = Number(version.slice(6, 8));
  const hour = Number(version.slice(8, 10));
  const minute = Number(version.slice(10, 12));
  const second = Number(version.slice(12, 14));
  const date = new Date(Date.UTC(year, month - 1, day, hour, minute, second));
  // Date.UTC 会把 2026-13-01 静默折算成 2027-01-01，所以必须回读比对，
  // 不能只看构造是否抛错。
  const roundTrips =
    date.getUTCFullYear() === year &&
    date.getUTCMonth() === month - 1 &&
    date.getUTCDate() === day &&
    date.getUTCHours() === hour &&
    date.getUTCMinutes() === minute &&
    date.getUTCSeconds() === second;
  return roundTrips ? date : null;
}

function checkMigrations(dir) {
  let entries;
  try {
    entries = readdirSync(dir);
  } catch (error) {
    const err = new Error(`无法读取迁移目录 ${dir}：${error.message}`);
    err.exitCode = 2;
    throw err;
  }

  const violations = [];
  const files = entries
    .filter((name) => !name.startsWith('.'))
    .filter((name) => statSync(join(dir, name)).isFile())
    .sort();

  // 目录里除了 .sql 不该有别的东西；CLI 会忽略它们，但沉默地忽略正是
  // 「以为提交了却没跑」这类事故的温床，所以显式报出来。
  for (const name of files) {
    if (!name.endsWith('.sql')) {
      violations.push({ rule: 'unexpected-file', file: name, detail: '迁移目录内出现非 .sql 文件' });
    }
  }

  const parsed = [];
  for (const name of files.filter((n) => n.endsWith('.sql'))) {
    const match = FILENAME_RE.exec(name);
    if (!match) {
      violations.push({
        rule: 'filename-format',
        file: name,
        detail: '文件名不符合 <14位时间戳>_<snake_case>.sql',
      });
      continue;
    }
    const [, version, slug] = match;
    if (!parseVersionTimestamp(version)) {
      violations.push({
        rule: 'version-not-a-timestamp',
        file: name,
        detail: `版本号 ${version} 不是合法的 UTC 时间戳（YYYYMMDDHHMMSS）`,
      });
      continue;
    }
    parsed.push({ file: name, version, slug });
  }

  const seen = new Map();
  for (const item of parsed) {
    if (seen.has(item.version)) {
      violations.push({
        rule: 'duplicate-version',
        file: item.file,
        detail: `版本号 ${item.version} 与 ${seen.get(item.version)} 重复`,
      });
    } else {
      seen.set(item.version, item.file);
    }
  }

  // parsed 已经按文件名字典序排列（CLI 的执行顺序）。因为版本号是定长 14 位
  // 数字前缀，字典序递增 ⇔ 数值递增，所以只要相邻两项非严格递增就说明
  // 「执行顺序」和「时间语义」对不上。
  for (let i = 1; i < parsed.length; i += 1) {
    const prev = parsed[i - 1];
    const curr = parsed[i];
    if (curr.version <= prev.version) {
      violations.push({
        rule: 'version-not-increasing',
        file: curr.file,
        detail: `版本号 ${curr.version} 未严格大于前一份 ${prev.version}（${prev.file}）`,
      });
    }
  }

  return { dir, count: parsed.length, migrations: parsed, violations };
}

function main() {
  let opts;
  try {
    opts = parseArgs(process.argv.slice(2));
  } catch (error) {
    process.stderr.write(`${error.message}\n\n${USAGE}`);
    process.exit(2);
  }

  if (opts.help) {
    process.stdout.write(USAGE);
    process.exit(0);
  }

  let result;
  try {
    result = checkMigrations(opts.dir);
  } catch (error) {
    process.stderr.write(`${error.message}\n`);
    process.exit(error.exitCode ?? 2);
  }

  if (opts.json) {
    process.stdout.write(`${JSON.stringify(result, null, 2)}\n`);
  } else {
    process.stdout.write(`迁移目录：${result.dir}\n`);
    process.stdout.write(`迁移文件数：${result.count}\n`);
    if (result.violations.length === 0) {
      process.stdout.write('结果：通过（命名格式、版本号合法性、唯一性、严格递增均无问题）\n');
    } else {
      process.stdout.write(`结果：发现 ${result.violations.length} 项违规\n\n`);
      for (const v of result.violations) {
        process.stdout.write(`  [${v.rule}] ${v.file}\n    ${v.detail}\n`);
      }
      process.stdout.write(
        '\n修复提示：迁移一旦部署就不能改名或删除（AGENTS.md：只新增迁移，不改写已部署迁移）。\n' +
          '若是尚未部署的新文件，直接改成 `supabase migration new <name>` 生成的时间戳即可；\n' +
          '若已经部署，请走 docs/architecture/supabase-migration-ledger-repair.md 的 repair 流程。\n',
      );
    }
  }

  process.exit(result.violations.length === 0 ? 0 : 1);
}

main();
