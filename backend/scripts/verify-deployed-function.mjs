#!/usr/bin/env node
// verify-deployed-function — answers ONE question: are the bytes currently
// running in Supabase identical to the bytes at a specific git commit?
//
// Why this exists (Issue #133): the weekly generation window was hot-fixed
// directly on the deployed function while `main` still carried the inverted
// predicate. Production was correct, the repo was not, and nothing in the
// pipeline could tell the difference — so the next routine `supabase
// functions deploy` from `main` would silently have restored the bug. A green
// test suite proves the *repo* is right; only reading the deployed bytes back
// proves the *deployment* is.
//
// The check is deliberately byte-for-byte rather than behavioral. Anything
// weaker (spot-checking one predicate, diffing "the important files",
// comparing timestamps) is exactly the kind of check that passed while the
// drift was already there.
//
// Usage:
//   SUPABASE_ACCESS_TOKEN=sbp_... \
//   node backend/scripts/verify-deployed-function.mjs \
//     --function generate-weekly-plan \
//     --commit  <sha|ref>  \
//     --project-ref <ref>            # or SUPABASE_PROJECT_REF
//     [--dump-dir <path>]            # keep the downloaded tree for inspection
//
// Exit codes:
//   0  deployed bytes == commit bytes
//   1  drift detected (missing / extra / differing file)
//   2  the check could not be performed (bad args, missing token, CLI or
//      network failure). NEVER conflated with 0: "we could not look" must not
//      read as "we looked and it was fine".
//
// Requires: git, the Supabase CLI on PATH, and a Management API access token
// with read access to the project. It performs no writes of any kind — there
// is no code path in this file that deploys, patches or deletes anything.

import { execFileSync } from 'node:child_process';
import { createHash } from 'node:crypto';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

/** Repo-relative root every path in this file is expressed against. Both the
 * git side and the downloaded side are keyed by paths relative to this, which
 * is what makes them comparable at all. */
export const FUNCTIONS_ROOT = 'backend/supabase/functions';

// Matches `from "x"`, `import "x"` and `import("x")`. Deliberately loose on
// syntax and strict on the result: only specifiers that start with ./ or ../
// are treated as local modules, so a stray "from" in prose cannot invent a
// phantom file — the worst a false match can do is name something that is not
// relative, which is then ignored.
const SPECIFIER_RE = /\b(?:from|import)\s*\(?\s*["']([^"']+)["']/g;

/**
 * The set of repo files that Supabase actually ships for one function: the
 * entrypoint plus the transitive closure of its *relative* imports.
 *
 * Why the closure and not "the function directory plus _shared": the deployed
 * eszip contains exactly the modules in the import graph. Comparing a
 * hand-maintained directory list would drift the moment someone adds or drops
 * a shared module — reintroducing, in the verifier itself, the same
 * "list maintained by hand next to the thing it describes" failure that this
 * whole script exists to catch. Remote specifiers (https:, jsr:, npm:) are
 * intentionally out of scope: they are pinned by URL and are not repo files.
 *
 * @param entry     path relative to FUNCTIONS_ROOT, e.g. 'generate-weekly-plan/index.ts'
 * @param readFile  (relPath) => string | null  — null means "does not exist"
 * @returns sorted array of paths relative to FUNCTIONS_ROOT
 */
export function collectLocalImportClosure(entry, readFile) {
  const seen = new Set();
  const queue = [entry];
  while (queue.length > 0) {
    const current = queue.shift();
    if (seen.has(current)) continue;
    const source = readFile(current);
    if (source === null || source === undefined) {
      throw new Error(`import closure: ${current} is referenced but does not exist`);
    }
    seen.add(current);
    for (const specifier of localSpecifiersIn(source)) {
      const resolved = resolveRelative(current, specifier);
      queue.push(resolved);
    }
  }
  return [...seen].sort();
}

function localSpecifiersIn(source) {
  const out = [];
  for (const match of source.matchAll(SPECIFIER_RE)) {
    const specifier = match[1];
    if (specifier.startsWith('./') || specifier.startsWith('../')) out.push(specifier);
  }
  return out;
}

/** Resolve `specifier` against `importer`'s directory, both relative to
 * FUNCTIONS_ROOT. Escaping the root is fatal rather than silently clamped:
 * such an import could never have been bundled, so seeing one means the
 * caller is verifying something other than what gets deployed. */
function resolveRelative(importer, specifier) {
  const joined = path.posix.normalize(path.posix.join(path.posix.dirname(importer), specifier));
  if (joined.startsWith('..')) {
    throw new Error(`import closure: ${importer} imports ${specifier}, which escapes ${FUNCTIONS_ROOT}`);
  }
  return joined;
}

/**
 * Compare two path -> content maps. Pure, so the reporting logic is testable
 * without a project, a token or a network.
 *
 * `missing`  — in the commit, absent from the deployment (deploy was partial,
 *              or ran from a tree that predates the file).
 * `extra`    — deployed but not in the commit (a hot-fixed or stale file left
 *              behind: literally the Issue #133 shape).
 * `changed`  — same path, different bytes.
 */
export function diffTrees(expected, actual) {
  const missing = [];
  const extra = [];
  const changed = [];
  for (const [rel, content] of expected) {
    if (!actual.has(rel)) { missing.push(rel); continue; }
    const deployed = actual.get(rel);
    if (!bytesEqual(content, deployed)) {
      changed.push({ path: rel, expectedSha: sha256(content), actualSha: sha256(deployed) });
    }
  }
  for (const rel of actual.keys()) {
    if (!expected.has(rel)) extra.push(rel);
  }
  return {
    missing: missing.sort(),
    extra: extra.sort(),
    changed: changed.sort((a, b) => a.path.localeCompare(b.path)),
    get ok() { return this.missing.length === 0 && this.extra.length === 0 && this.changed.length === 0; },
  };
}

function toBuffer(value) {
  return Buffer.isBuffer(value) ? value : Buffer.from(value, 'utf8');
}

function bytesEqual(a, b) {
  return toBuffer(a).equals(toBuffer(b));
}

export function sha256(value) {
  return createHash('sha256').update(toBuffer(value)).digest('hex');
}

// MARK: - I/O side (not unit-tested; exercised by the runbook, see
// docs/architecture/edge-function-release-runbook.md)

function parseArgs(argv) {
  const args = { dumpDir: null };
  for (let i = 0; i < argv.length; i++) {
    const [flag, inlineValue] = argv[i].includes('=') ? argv[i].split(/=(.*)/s) : [argv[i], undefined];
    const value = () => (inlineValue !== undefined ? inlineValue : argv[++i]);
    switch (flag) {
      case '--function': args.fn = value(); break;
      case '--commit': args.commit = value(); break;
      case '--project-ref': args.projectRef = value(); break;
      case '--dump-dir': args.dumpDir = value(); break;
      case '--deployed-dir': args.deployedDir = value(); break;
      case '--help': case '-h': args.help = true; break;
      default: throw new Error(`unknown argument: ${flag}`);
    }
  }
  args.projectRef ??= process.env.SUPABASE_PROJECT_REF;
  return args;
}

function git(args, options = {}) {
  return execFileSync('git', args, { encoding: 'buffer', maxBuffer: 64 * 1024 * 1024, ...options });
}

/** Read the commit's version of the tree straight out of the object database
 * (`git show <sha>:<path>`), never the working tree. The working tree can be
 * dirty, mid-rebase, or on another branch entirely; the whole point is to
 * verify against an immutable commit. */
function readFromCommit(sha, repoRelPath) {
  try {
    // stderr is swallowed on purpose: "does not exist in <sha>" is an expected
    // answer here (that is how a missing file is detected), and letting git's
    // own `fatal:` line through would read as a crash in an otherwise
    // successful run.
    return git(['show', `${sha}:${repoRelPath}`], { stdio: ['ignore', 'pipe', 'ignore'] });
  } catch {
    return null;
  }
}

function walkFiles(dir, base = dir) {
  const out = [];
  for (const entry of fs.readdirSync(dir, { withFileTypes: true })) {
    const full = path.join(dir, entry.name);
    if (entry.isDirectory()) out.push(...walkFiles(full, base));
    else if (entry.isFile()) out.push(path.relative(base, full).split(path.sep).join('/'));
  }
  return out;
}

/**
 * Pull the deployed source back down.
 *
 * `--use-api` unbundles the eszip server-side, which is what makes this
 * runnable on a plain CI runner: the default path shells out to Docker, which
 * GitHub-hosted Linux runners have but which turns a 5-second check into a
 * multi-minute image pull. We download into a throwaway workdir seeded with a
 * copy of config.toml rather than pointing the CLI at `backend/`, because
 * `functions download` writes into `<workdir>/supabase/functions/` — aimed at
 * the repo it would overwrite the very source files we are about to compare
 * against, and the check would then trivially "pass".
 */
function downloadDeployedFunction({ fn, projectRef, workdir, repoRoot }) {
  fs.mkdirSync(path.join(workdir, 'supabase'), { recursive: true });
  fs.copyFileSync(
    path.join(repoRoot, 'backend/supabase/config.toml'),
    path.join(workdir, 'supabase/config.toml')
  );
  execFileSync('supabase', ['functions', 'download', fn, '--project-ref', projectRef, '--use-api', '--workdir', workdir], {
    stdio: ['ignore', 'inherit', 'inherit'],
  });
  const root = path.join(workdir, 'supabase', 'functions');
  if (!fs.existsSync(root)) {
    throw new Error(`supabase functions download produced no ${root}`);
  }
  return root;
}

/** Deployed version / status, for the release log. Informational only — the
 * byte comparison is the gate, and a metadata hiccup must not be able to turn
 * a real drift into a pass, so failures here are warnings. */
async function fetchFunctionMetadata(projectRef, fn, token) {
  try {
    const response = await fetch(`https://api.supabase.com/v1/projects/${projectRef}/functions/${fn}`, {
      headers: { Authorization: `Bearer ${token}` },
    });
    if (!response.ok) return { warning: `Management API returned ${response.status}` };
    const body = await response.json();
    return { version: body.version, status: body.status, updatedAt: body.updated_at && new Date(body.updated_at).toISOString() };
  } catch (error) {
    return { warning: `Management API unreachable: ${error.message}` };
  }
}

const USAGE = `usage: verify-deployed-function.mjs --function <name> --commit <sha|ref>
              [--project-ref <ref>] [--dump-dir <path>] [--deployed-dir <path>]

  --project-ref   Supabase project to read the deployment from (or SUPABASE_PROJECT_REF).
  --dump-dir      Keep the downloaded tree here instead of a temp dir.
  --deployed-dir  Compare against an already-downloaded functions/ tree instead of
                  calling Supabase. For reproducing a failed CI run offline, and for
                  the case where the tree was obtained some other way (Docker
                  unbundle, support export). No token or network needed.

env: SUPABASE_ACCESS_TOKEN (required unless --deployed-dir)
     SUPABASE_PROJECT_REF  (unless --project-ref or --deployed-dir)`;

async function main(argv) {
  let args;
  try {
    args = parseArgs(argv);
  } catch (error) {
    console.error(`${error.message}\n\n${USAGE}`);
    return 2;
  }
  if (args.help) { console.log(USAGE); return 0; }
  if (!args.fn || !args.commit) { console.error(USAGE); return 2; }
  if (!args.deployedDir) {
    if (!args.projectRef) { console.error(USAGE); return 2; }
    // Exit 2, never 0: "we could not look" must never be reported as "we
    // looked and it matched". Every failure to obtain the deployed bytes ends
    // here or below with 2, so a green result always means a real comparison
    // happened.
    if (!process.env.SUPABASE_ACCESS_TOKEN) {
      console.error('SUPABASE_ACCESS_TOKEN is not set — refusing to report a result we did not actually check.');
      return 2;
    }
  }

  const repoRoot = git(['rev-parse', '--show-toplevel']).toString().trim();
  let sha;
  try {
    sha = git(['rev-parse', '--verify', `${args.commit}^{commit}`], { stdio: ['ignore', 'pipe', 'pipe'] }).toString().trim();
  } catch {
    console.error(`not a commit in this repository: ${args.commit}`);
    return 2;
  }

  const entry = `${args.fn}/index.ts`;
  let expectedPaths;
  try {
    expectedPaths = collectLocalImportClosure(entry, (rel) => {
      const buffer = readFromCommit(sha, `${FUNCTIONS_ROOT}/${rel}`);
      return buffer === null ? null : buffer.toString('utf8');
    });
  } catch (error) {
    console.error(`${error.message} (at commit ${sha})`);
    return 2;
  }
  const expected = new Map(expectedPaths.map((rel) => [rel, readFromCommit(sha, `${FUNCTIONS_ROOT}/${rel}`)]));

  let downloadRoot;
  if (args.deployedDir) {
    downloadRoot = path.resolve(args.deployedDir);
    if (!fs.existsSync(downloadRoot)) { console.error(`--deployed-dir does not exist: ${downloadRoot}`); return 2; }
  } else {
    let workdir;
    if (args.dumpDir) {
      workdir = path.resolve(args.dumpDir);
      fs.mkdirSync(workdir, { recursive: true });
    } else {
      workdir = fs.mkdtempSync(path.join(os.tmpdir(), 'peaklog-deployed-'));
    }
    try {
      downloadRoot = downloadDeployedFunction({ fn: args.fn, projectRef: args.projectRef, workdir, repoRoot });
    } catch (error) {
      console.error(`could not download the deployed function: ${error.message}`);
      return 2;
    }
  }
  const actual = new Map(walkFiles(downloadRoot).map((rel) => [rel, fs.readFileSync(path.join(downloadRoot, rel))]));

  const metadata = args.deployedDir
    ? { warning: 'offline comparison (--deployed-dir): deployed version not read from the API' }
    : await fetchFunctionMetadata(args.projectRef, args.fn, process.env.SUPABASE_ACCESS_TOKEN);
  const result = diffTrees(expected, actual);

  console.log(`function     : ${args.fn}`);
  console.log(`project      : ${args.projectRef ?? '(offline)'}`);
  console.log(`commit       : ${sha}`);
  console.log(`deployed ver : ${metadata.version ?? '(unknown)'}${metadata.status ? ` (${metadata.status})` : ''}${metadata.updatedAt ? ` updated ${metadata.updatedAt}` : ''}`);
  if (metadata.warning) console.log(`               warning: ${metadata.warning}`);
  console.log(`compared to  : ${downloadRoot}`);
  console.log('');
  for (const rel of [...expected.keys()].sort()) {
    const status = result.missing.includes(rel) ? 'MISSING'
      : result.changed.some((c) => c.path === rel) ? 'DIFFERS'
        : 'ok';
    console.log(`  ${status.padEnd(8)} ${rel}  ${sha256(expected.get(rel)).slice(0, 12)}`);
  }
  for (const rel of result.extra) console.log(`  EXTRA    ${rel}`);

  if (result.ok) {
    console.log(`\nOK — all ${expected.size} deployed files are byte-identical to ${sha.slice(0, 7)}.`);
    return 0;
  }
  console.error('\nDRIFT — the deployed function does not match the commit.');
  for (const rel of result.missing) console.error(`  missing from deployment: ${rel}`);
  for (const rel of result.extra) console.error(`  present only in deployment: ${rel}`);
  for (const c of result.changed) console.error(`  differs: ${c.path}\n      commit   ${c.expectedSha}\n      deployed ${c.actualSha}`);
  console.error('\nDo NOT "fix" this by deploying whatever is currently checked out.');
  console.error('See docs/architecture/edge-function-release-runbook.md — 校验失败与回滚.');
  return 1;
}

// Only run when executed directly, so the pure helpers above can be imported
// by backend/tests/verifyDeployedFunction.test.mjs without side effects.
if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  main(process.argv.slice(2)).then(
    (code) => { process.exitCode = code; },
    // An unexpected throw inside main() would otherwise surface as an
    // unhandled rejection, which Node exits with code 1 — the code this
    // script reserves for "checked, and it drifted". A crash must land in the
    // "could not check" bucket instead, or the release runbook's whole
    // 1-vs-2 distinction leaks: an operator would go hunting for a drift that
    // was never actually observed.
    (error) => {
      console.error(`verify-deployed-function crashed before it could compare anything:\n${error?.stack ?? error}`);
      process.exitCode = 2;
    }
  );
}
