import { test } from 'node:test';
import assert from 'node:assert/strict';
import {
  localWeekdayAndHour,
  isGenerationWindowOpen,
  isInferenceWindowOpen,
  nextMondayString,
  thisMondayString,
  localDateString,
} from '../supabase/functions/_shared/generationWindow.mjs';
import { localMidnightToUtc } from '../supabase/functions/_shared/timezone.mjs';

// 2026-07-12 is a Sunday; 07-13 Monday, 07-15 Wednesday, 07-18 Saturday.
const SUNDAY = '2026-07-12';
const MONDAY = '2026-07-13';
const WEDNESDAY = '2026-07-15';
const SATURDAY = '2026-07-18';

// Timezones spanning the full offset range, so a predicate that accidentally
// reasons in UTC instead of local time cannot pass. All are DST-stable in
// mid-July, so local-midnight + N hours is an exact wall-clock construction.
const ZONES = ['UTC', 'Asia/Shanghai', 'America/Los_Angeles', 'Pacific/Kiritimati', 'Etc/GMT+12'];

/** The UTC instant at which `timezone`'s wall clock reads `dateStr hh:mm`. */
function instantAt(timezone, dateStr, hh, mm = 0) {
  const instant = new Date(localMidnightToUtc(dateStr, timezone).getTime() + (hh * 60 + mm) * 60_000);
  // Self-check: the construction must actually land on the wall clock we
  // meant, otherwise every assertion below would be testing the wrong instant.
  const { hour } = localWeekdayAndHour(timezone, instant);
  assert.equal(hour, hh, `instantAt(${timezone}, ${dateStr}, ${hh}) landed on local hour ${hour}`);
  assert.equal(localDateString(timezone, instant), dateStr);
  return instant;
}

// MARK: - The four required boundaries (plan §8.2: "周日 20:00 后第一个整点")

const BOUNDARIES = [
  { label: 'Sunday 19:59 — one minute too early', date: SUNDAY, hh: 19, mm: 59, open: false },
  { label: 'Sunday 20:00 — the window opens', date: SUNDAY, hh: 20, mm: 0, open: true },
  { label: 'Monday 09:00 — the week has already started', date: MONDAY, hh: 9, mm: 0, open: false },
  { label: 'Wednesday 12:00 — mid-week', date: WEDNESDAY, hh: 12, mm: 0, open: false },
];

for (const { label, date, hh, mm, open } of BOUNDARIES) {
  for (const tz of ZONES) {
    test(`isGenerationWindowOpen: ${label} is ${open ? 'OPEN' : 'CLOSED'} (${tz})`, () => {
      assert.equal(isGenerationWindowOpen(tz, instantAt(tz, date, hh, mm)), open);
    });
  }
}

// MARK: - The rest of the Sunday evening, and everything outside it

test('the whole Sunday evening stays open — 20/21/22/23 are the four catch-up ticks', () => {
  for (const hh of [20, 21, 22, 23]) {
    assert.equal(isGenerationWindowOpen('Asia/Shanghai', instantAt('Asia/Shanghai', SUNDAY, hh)), true, `Sunday ${hh}:00`);
  }
});

test('every other hour of the week is closed', () => {
  const tz = 'Asia/Shanghai';
  for (let hh = 0; hh < 20; hh++) {
    assert.equal(isGenerationWindowOpen(tz, instantAt(tz, SUNDAY, hh)), false, `Sunday ${hh}:00`);
  }
  for (const date of [MONDAY, WEDNESDAY, SATURDAY]) {
    for (let hh = 0; hh < 24; hh++) {
      assert.equal(isGenerationWindowOpen(tz, instantAt(tz, date, hh)), false, `${date} ${hh}:00`);
    }
  }
});

// MARK: - Regression guard: why the window MUST stay bounded to Sunday
//
// The window predicate is only half of "which week am I generating?" — the
// other half is nextMondayString, which derives the target from `now`. The
// bug was `weekday !== 0 || hour >= 20` (the negation of the intent), which
// left the window open Mon–Sat; the first Monday-00:00 tick then targeted a
// Monday two weeks out, generating next week's plan a full week early off a
// week with zero training logged. The real Sunday 20:00 run afterwards always
// hit the "plan already exists" idempotency check and became a no-op.

const buggyPredicate = (tz, now) => {
  const { weekday, hour } = localWeekdayAndHour(tz, now);
  return weekday !== 0 || hour >= 20;
};

test('the old predicate opened the window at Monday 00:00 — the new one does not', () => {
  const tz = 'Asia/Shanghai';
  const mondayMidnight = instantAt(tz, MONDAY, 0);
  assert.equal(buggyPredicate(tz, mondayMidnight), true, 'precondition: the old predicate was open here');
  assert.equal(isGenerationWindowOpen(tz, mondayMidnight), false);
});

test('a Monday tick would target the week AFTER next — a week early, off an untrained week', () => {
  const tz = 'Asia/Shanghai';
  const sundayEvening = instantAt(tz, SUNDAY, 20);
  const mondayMidnight = instantAt(tz, MONDAY, 0);

  // Four hours apart in wall-clock time, but a whole week apart in target.
  assert.equal(nextMondayString(tz, sundayEvening), MONDAY, 'Sunday 20:00 plans the week starting tomorrow');
  assert.equal(nextMondayString(tz, mondayMidnight), '2026-07-20', 'Monday 00:00 plans the week after next');

  // Which is exactly why only the first may be allowed through.
  assert.equal(isGenerationWindowOpen(tz, sundayEvening), true);
  assert.equal(isGenerationWindowOpen(tz, mondayMidnight), false);
});

test('every open tick of a Sunday targets the very next day (the Monday about to start)', () => {
  for (const tz of ZONES) {
    for (const hh of [20, 21, 22, 23]) {
      const now = instantAt(tz, SUNDAY, hh);
      assert.equal(isGenerationWindowOpen(tz, now), true);
      assert.equal(nextMondayString(tz, now), MONDAY, `${tz} Sunday ${hh}:00`);
      assert.equal(thisMondayString(tz, now), '2026-07-06', `${tz} Sunday ${hh}:00 is still last Monday's week`);
    }
  }
});

// An hourly cron over five weeks must fire on exactly five distinct target
// weeks, each one the Monday immediately following the Sunday it fired on —
// i.e. plans are never generated more than one day ahead of the week they are
// for. This is the property the inverted predicate broke.
test('an hourly sweep generates each week exactly once, always the night before', () => {
  for (const tz of ['UTC', 'Asia/Shanghai', 'America/Los_Angeles']) {
    const installed = new Set();
    const fired = [];
    let t = Date.parse('2026-06-01T00:00:00Z');
    for (let i = 0; i < 24 * 35; i++, t += 3_600_000) {
      const now = new Date(t);
      if (!isGenerationWindowOpen(tz, now)) continue;
      const target = nextMondayString(tz, now);
      if (installed.has(target)) continue; // the "plan already exists" check
      installed.add(target);
      fired.push({ target, firedOn: localDateString(tz, now), weekday: localWeekdayAndHour(tz, now).weekday });
    }

    assert.equal(fired.length, 5, `${tz}: expected one generation per week`);
    for (const { target, firedOn, weekday } of fired) {
      assert.equal(weekday, 0, `${tz}: generation must fire on a Sunday`);
      const dayBeforeTarget = new Date(Date.parse(`${target}T00:00:00Z`) - 86_400_000).toISOString().slice(0, 10);
      assert.equal(firedOn, dayBeforeTarget, `${tz}: plan for ${target} must be generated on ${dayBeforeTarget}`);
    }
  }
});

// MARK: - Helpers moved alongside the predicate keep their behavior

test('thisMondayString treats Sunday as the END of its week, not the start', () => {
  const tz = 'UTC';
  assert.equal(thisMondayString(tz, instantAt(tz, SUNDAY, 12)), '2026-07-06');
  assert.equal(thisMondayString(tz, instantAt(tz, MONDAY, 12)), MONDAY);
  assert.equal(thisMondayString(tz, instantAt(tz, WEDNESDAY, 12)), MONDAY);
  assert.equal(nextMondayString(tz, instantAt(tz, SUNDAY, 12)), MONDAY);
});

test('week boundaries are read in the user local clock, not UTC', () => {
  // 2026-07-12 21:00 in Kiritimati (UTC+14) is still 2026-07-12 07:00 UTC —
  // same day. The reverse case is the sharp one: 2026-07-12 21:00 in
  // Etc/GMT+12 is 2026-07-13 09:00 UTC, i.e. a UTC Monday. A UTC-based
  // predicate would refuse to generate for that user at all.
  const tz = 'Etc/GMT+12';
  const sundayEvening = instantAt(tz, SUNDAY, 21);
  assert.equal(sundayEvening.toISOString().slice(0, 10), MONDAY, 'precondition: it is Monday in UTC');
  assert.equal(isGenerationWindowOpen(tz, sundayEvening), true);
  assert.equal(nextMondayString(tz, sundayEvening), MONDAY);
});

// MARK: - Corrupt profiles.timezone must not starve the whole sweep
//
// profiles.timezone is a free-form varchar(64) with no CHECK constraint, and
// Intl.DateTimeFormat throws RangeError on an unrecognized name. Since
// selectDueUsers / runInferenceSweep iterate profiles without a per-profile
// try/catch, an unguarded throw aborts the entire hourly sweep with a 500 --
// one corrupt row would block weekly generation for every other user.

const BAD_TIMEZONES = ['Asia/Shanghi', 'GMT+8', 'not a zone', '', null, undefined];

test('precondition: these values really do make Intl throw', () => {
  for (const tz of BAD_TIMEZONES) {
    if (tz == null) continue; // null/undefined are caught by the falsy guard
    assert.throws(() => new Intl.DateTimeFormat('en-US', { timeZone: tz }), RangeError, `expected ${JSON.stringify(tz)} to throw`);
  }
});

test('every exported function tolerates an unrecognized timezone by falling back to UTC', () => {
  const now = new Date('2026-07-12T21:30:00Z'); // Sunday 21:30 UTC
  for (const tz of BAD_TIMEZONES) {
    assert.doesNotThrow(() => localWeekdayAndHour(tz, now), `localWeekdayAndHour(${JSON.stringify(tz)})`);
    assert.deepEqual(localWeekdayAndHour(tz, now), localWeekdayAndHour('UTC', now));
    assert.equal(isGenerationWindowOpen(tz, now), isGenerationWindowOpen('UTC', now));
    assert.equal(isInferenceWindowOpen(tz, now), isInferenceWindowOpen('UTC', now));
    assert.equal(localDateString(tz, now), localDateString('UTC', now));
    assert.equal(thisMondayString(tz, now), thisMondayString('UTC', now));
    assert.equal(nextMondayString(tz, now), nextMondayString('UTC', now));
  }
  // And UTC's own answer at that instant is the real one, not a swallowed error.
  assert.equal(isGenerationWindowOpen('Asia/Shanghi', now), true); // Sun 21:30 UTC
  assert.equal(nextMondayString('Asia/Shanghi', now), MONDAY);
});

test('a corrupt profile does not abort the sweep over the remaining profiles', () => {
  // Mirrors selectDueUsers' loop shape: a plain for-of with no try/catch.
  const profiles = [
    { id: 'a', timezone: 'Asia/Shanghai' },
    { id: 'b', timezone: 'Asia/Shanghi' }, // typo -- the corrupt row
    { id: 'c', timezone: 'UTC' },
  ];
  const now = instantAt('UTC', SUNDAY, 21);
  const seen = [];
  assert.doesNotThrow(() => {
    for (const p of profiles) {
      isGenerationWindowOpen(p.timezone || 'UTC', now);
      seen.push(p.id);
    }
  });
  assert.deepEqual(seen, ['a', 'b', 'c'], 'all three profiles must be evaluated');
});

test('a valid but non-IANA-looking alias is still honored, not silently coerced', () => {
  // 'PST' is a legacy alias Intl accepts; the guard must not clobber anything
  // Intl can actually resolve, or real users would get the wrong clock.
  const now = new Date('2026-07-12T12:00:00Z');
  assert.equal(localDateString('PST', now), localDateString('America/Los_Angeles', now));
});

test('isInferenceWindowOpen still spans local 21:00–22:59 only', () => {
  const tz = 'Asia/Shanghai';
  assert.equal(isInferenceWindowOpen(tz, instantAt(tz, WEDNESDAY, 20, 59)), false);
  assert.equal(isInferenceWindowOpen(tz, instantAt(tz, WEDNESDAY, 21)), true);
  assert.equal(isInferenceWindowOpen(tz, instantAt(tz, WEDNESDAY, 22)), true);
  assert.equal(isInferenceWindowOpen(tz, instantAt(tz, WEDNESDAY, 23)), false);
  // Unlike weekly generation, inference is a daily gate — Sunday is not special.
  assert.equal(isInferenceWindowOpen(tz, instantAt(tz, SUNDAY, 21)), true);
});
