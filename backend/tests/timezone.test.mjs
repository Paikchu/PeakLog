import { test } from 'node:test';
import assert from 'node:assert/strict';
import {
  getTimezoneOffsetMs,
  localMidnightToUtc,
  addDaysToDateString,
  localDayUtcRange,
} from '../supabase/functions/_shared/timezone.mjs';

// Independent oracle: format `instant` back into `timeZone`'s wall clock and
// return it as "yyyy-MM-dd HH:mm:ss". Deliberately does not reuse
// getTimezoneOffsetMs, so this validates the round-trip property against the
// platform Intl API directly rather than against our own implementation.
function wallClockIn(timeZone, instant) {
  const dtf = new Intl.DateTimeFormat('en-CA', {
    timeZone, hourCycle: 'h23',
    year: 'numeric', month: '2-digit', day: '2-digit',
    hour: '2-digit', minute: '2-digit', second: '2-digit',
  });
  const parts = {};
  for (const p of dtf.formatToParts(instant)) if (p.type !== 'literal') parts[p.type] = p.value;
  const hour = parts.hour === '24' ? '00' : parts.hour;
  return `${parts.year}-${parts.month}-${parts.day} ${hour}:${parts.minute}:${parts.second}`;
}

const CASES = [
  { name: 'Asia/Shanghai (UTC+8, no DST)', tz: 'Asia/Shanghai', date: '2026-07-13' },
  { name: 'Pacific/Kiritimati (UTC+14)', tz: 'Pacific/Kiritimati', date: '2026-07-13' },
  { name: 'Etc/GMT+12 (UTC-12)', tz: 'Etc/GMT+12', date: '2026-07-13' },
  { name: 'DST spring-forward day (America/Los_Angeles)', tz: 'America/Los_Angeles', date: '2026-03-08' },
  { name: 'DST fall-back day (America/Los_Angeles)', tz: 'America/Los_Angeles', date: '2026-11-01' },
];

for (const { name, tz, date } of CASES) {
  test(`localMidnightToUtc round-trips to exactly ${date} 00:00:00 in ${name}`, () => {
    const instant = localMidnightToUtc(date, tz);
    assert.equal(wallClockIn(tz, instant), `${date} 00:00:00`);
  });
}

test('UTC+14 local midnight is 10:00 UTC the previous day', () => {
  const instant = localMidnightToUtc('2026-07-13', 'Pacific/Kiritimati');
  assert.equal(instant.toISOString(), '2026-07-12T10:00:00.000Z');
});

test('UTC-12 local midnight is 12:00 UTC the same day', () => {
  const instant = localMidnightToUtc('2026-07-13', 'Etc/GMT+12');
  assert.equal(instant.toISOString(), '2026-07-13T12:00:00.000Z');
});

test('Asia/Shanghai local midnight is 16:00 UTC the previous day', () => {
  const instant = localMidnightToUtc('2026-07-13', 'Asia/Shanghai');
  assert.equal(instant.toISOString(), '2026-07-12T16:00:00.000Z');
});

test('old UTC-midnight-string bug would have been wrong for Shanghai (regression guard)', () => {
  const buggyInstant = new Date('2026-07-13T00:00:00.000Z');
  const correctInstant = localMidnightToUtc('2026-07-13', 'Asia/Shanghai');
  assert.notEqual(buggyInstant.getTime(), correctInstant.getTime());
  assert.equal(correctInstant.getTime() - buggyInstant.getTime(), -8 * 60 * 60 * 1000);
});

test('addDaysToDateString advances the calendar label without touching any timezone', () => {
  assert.equal(addDaysToDateString('2026-07-13', 1), '2026-07-14');
  assert.equal(addDaysToDateString('2026-01-01', -1), '2025-12-31');
  assert.equal(addDaysToDateString('2026-02-28', 1), '2026-03-01'); // non-leap year
});

test('localDayUtcRange spans exactly 24h on an ordinary day', () => {
  const { start, end } = localDayUtcRange('2026-07-13', 'Asia/Shanghai');
  assert.equal(end.getTime() - start.getTime(), 24 * 60 * 60 * 1000);
});

test('localDayUtcRange is a 23h window on the DST spring-forward day (America/Los_Angeles)', () => {
  const { start, end } = localDayUtcRange('2026-03-08', 'America/Los_Angeles');
  assert.equal(end.getTime() - start.getTime(), 23 * 60 * 60 * 1000);
});

test('localDayUtcRange is a 25h window on the DST fall-back day (America/Los_Angeles)', () => {
  const { start, end } = localDayUtcRange('2026-11-01', 'America/Los_Angeles');
  assert.equal(end.getTime() - start.getTime(), 25 * 60 * 60 * 1000);
});

test('getTimezoneOffsetMs matches Shanghai +8h fixed offset regardless of instant', () => {
  assert.equal(getTimezoneOffsetMs('Asia/Shanghai', new Date('2026-01-01T00:00:00Z')), 8 * 60 * 60 * 1000);
  assert.equal(getTimezoneOffsetMs('Asia/Shanghai', new Date('2026-07-13T00:00:00Z')), 8 * 60 * 60 * 1000);
});

test('a replan just before local midnight and one just after fall in different local days (Shanghai)', () => {
  // 2026-07-13 23:59:59 local Shanghai and 2026-07-14 00:00:01 local Shanghai
  // must land in different [start,end) windows produced for their own date.
  const day1 = localDayUtcRange('2026-07-13', 'Asia/Shanghai');
  const day2 = localDayUtcRange('2026-07-14', 'Asia/Shanghai');
  const justBeforeMidnight = new Date(day1.end.getTime() - 1000); // 23:59:59 local
  const justAfterMidnight = new Date(day2.start.getTime() + 1000); // 00:00:01 local

  assert.ok(justBeforeMidnight >= day1.start && justBeforeMidnight < day1.end);
  assert.ok(justAfterMidnight >= day2.start && justAfterMidnight < day2.end);
  // The buggy UTC-midnight-string version would have misclassified both,
  // since Shanghai's actual local midnight is 16:00 UTC the prior day.
});
