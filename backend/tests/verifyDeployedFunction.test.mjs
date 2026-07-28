import { test } from 'node:test';
import assert from 'node:assert/strict';
import { execFileSync } from 'node:child_process';
import {
  FUNCTIONS_ROOT,
  collectLocalImportClosure,
  diffTrees,
  sha256,
} from '../scripts/verify-deployed-function.mjs';

// The release gate for Issue #133 is only as trustworthy as its comparison
// logic: a verifier that quietly under-collects files, or that reports "ok"
// on a difference, is worse than no verifier at all — it converts an unknown
// into a false assurance. So the two pure halves (which files belong to a
// deployment, and how two trees differ) are pinned here.

// MARK: - Which files a deployment is made of

const VIRTUAL = {
  'fn/index.ts': `
    import "jsr:@supabase/functions-js/edge-runtime.d.ts";
    import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
    import { a } from "../_shared/a.mjs";
    import { b } from "./local.mjs";
  `,
  'fn/local.mjs': `export const b = 1;`,
  '_shared/a.mjs': `import { c } from './c.mjs'; export const a = c;`,
  '_shared/c.mjs': `export const c = 2;`,
  '_shared/unrelated.mjs': `export const nope = 3;`,
};

const readVirtual = (rel) => (rel in VIRTUAL ? VIRTUAL[rel] : null);

test('the closure follows relative imports transitively and normalizes ../ back to root', () => {
  assert.deepEqual(collectLocalImportClosure('fn/index.ts', readVirtual), [
    '_shared/a.mjs',
    '_shared/c.mjs',
    'fn/index.ts',
    'fn/local.mjs',
  ]);
});

test('a shared file nothing imports is NOT part of the deployment', () => {
  // Supabase ships the eszip'd import graph, not a directory. Including
  // _shared wholesale would report phantom drift for any module this
  // particular function does not use.
  assert.ok(!collectLocalImportClosure('fn/index.ts', readVirtual).includes('_shared/unrelated.mjs'));
});

test('remote specifiers are out of scope — they are pinned by URL, not repo files', () => {
  const closure = collectLocalImportClosure('fn/index.ts', readVirtual);
  assert.ok(!closure.some((p) => p.includes('esm.sh') || p.includes('jsr:')));
});

test('an import that resolves to a missing file is fatal, not silently dropped', () => {
  // Silently dropping it is the dangerous failure: the file would then be
  // absent from BOTH sides of the diff and the check would pass.
  const broken = { 'fn/index.ts': `import { x } from "../_shared/typo.mjs";` };
  assert.throws(
    () => collectLocalImportClosure('fn/index.ts', (rel) => broken[rel] ?? null),
    /_shared\/typo\.mjs is referenced but does not exist/
  );
});

test('an import escaping the functions root is rejected rather than clamped', () => {
  const escaping = { 'fn/index.ts': `import { x } from "../../migrations/oops.sql";` };
  assert.throws(
    () => collectLocalImportClosure('fn/index.ts', (rel) => escaping[rel] ?? null),
    /escapes backend\/supabase\/functions/
  );
});

test('a cyclic import graph terminates', () => {
  const cyclic = {
    'fn/index.ts': `import './a.mjs';`,
    'fn/a.mjs': `import './b.mjs';`,
    'fn/b.mjs': `import './a.mjs';`,
  };
  assert.deepEqual(collectLocalImportClosure('fn/index.ts', (rel) => cyclic[rel] ?? null), [
    'fn/a.mjs', 'fn/b.mjs', 'fn/index.ts',
  ]);
});

// MARK: - Against the real repository
//
// The virtual fixtures prove the algorithm; this proves it is pointed at
// something real. If generate-weekly-plan ever drops or gains a shared
// module, this test is the one that notices — and the release runbook's file
// list stops being a hand-maintained lie.

test('the real generate-weekly-plan closure is the entrypoint plus its nine shared modules', () => {
  const repoRoot = execFileSync('git', ['rev-parse', '--show-toplevel'], { encoding: 'utf8' }).trim();
  const readFromHead = (rel) => {
    try {
      return execFileSync('git', ['show', `HEAD:${FUNCTIONS_ROOT}/${rel}`], {
        cwd: repoRoot, encoding: 'utf8', stdio: ['ignore', 'pipe', 'ignore'],
      });
    } catch {
      return null;
    }
  };

  assert.deepEqual(collectLocalImportClosure('generate-weekly-plan/index.ts', readFromHead), [
    '_shared/contextBuilder.mjs',
    '_shared/exerciseLibrary.mjs',
    '_shared/generationWindow.mjs',
    '_shared/llm.mjs',
    '_shared/ownershipQueries.mjs',
    '_shared/prompt.mjs',
    '_shared/referenceWeight.mjs',
    '_shared/timezone.mjs',
    '_shared/validator.mjs',
    'generate-weekly-plan/index.ts',
  ]);
});

// MARK: - How two trees are compared

const tree = (entries) => new Map(Object.entries(entries));

test('identical trees compare clean', () => {
  const result = diffTrees(tree({ 'a.mjs': 'x', 'b.ts': 'y' }), tree({ 'a.mjs': 'x', 'b.ts': 'y' }));
  assert.equal(result.ok, true);
  assert.deepEqual([result.missing, result.extra, result.changed], [[], [], []]);
});

test('a one-character difference is drift — this is the whole point of the check', () => {
  // The Issue #133 shape in miniature: `weekday === 0` deployed vs
  // `weekday !== 0` committed. Nothing about file counts or names changes.
  const committed = tree({ 'w.mjs': 'return weekday === 0 && hour >= 20;' });
  const deployed = tree({ 'w.mjs': 'return weekday !== 0 || hour >= 20;' });
  const result = diffTrees(committed, deployed);
  assert.equal(result.ok, false);
  assert.equal(result.changed.length, 1);
  assert.equal(result.changed[0].path, 'w.mjs');
  assert.notEqual(result.changed[0].expectedSha, result.changed[0].actualSha);
});

test('trailing-whitespace and newline changes count as drift, not noise', () => {
  // Deliberate: any normalization is a hole a hot-fix could hide in, and the
  // deploy pipeline does not normalize either.
  assert.equal(diffTrees(tree({ 'a.mjs': 'x\n' }), tree({ 'a.mjs': 'x' })).ok, false);
});

test('a file deployed but not committed is reported as extra, not ignored', () => {
  // Left-behind hot-fix modules are invisible to any check that only walks
  // the committed side.
  const result = diffTrees(tree({ 'a.mjs': 'x' }), tree({ 'a.mjs': 'x', 'hotfix.mjs': 'z' }));
  assert.equal(result.ok, false);
  assert.deepEqual(result.extra, ['hotfix.mjs']);
});

test('a file committed but not deployed is reported as missing', () => {
  const result = diffTrees(tree({ 'a.mjs': 'x', 'b.mjs': 'y' }), tree({ 'a.mjs': 'x' }));
  assert.equal(result.ok, false);
  assert.deepEqual(result.missing, ['b.mjs']);
});

test('Buffer and string contents compare on bytes, not on representation', () => {
  // The commit side arrives as a Buffer from `git show`, the deployed side as
  // a Buffer from disk; the fixtures above are strings. All three must mean
  // the same thing, or the tests would be validating a code path production
  // never takes.
  assert.equal(diffTrees(tree({ 'a.mjs': Buffer.from('x') }), tree({ 'a.mjs': 'x' })).ok, true);
  assert.equal(sha256('x'), sha256(Buffer.from('x')));
  assert.equal(sha256(''), 'e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855');
});
