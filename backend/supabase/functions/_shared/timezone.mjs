// Pure timezone/instant arithmetic — no I/O, no Deno-specific APIs. Consumed
// by generate-weekly-plan/index.ts for the daily replan quota and behavioral
// inference gate, and independently unit-tested
// (backend/tests/timezone.test.mjs) via `node --test`.
//
// Issue #71: those two checks used to build the "start of today" boundary by
// taking the user's LOCAL calendar date string (yyyy-MM-dd) and appending
// "T00:00:00Z" — i.e. UTC midnight of that date, not the user's actual local
// midnight. For any non-UTC timezone this shifts the daily window by the
// timezone offset (e.g. up to 8h early for UTC+8, 8h late for UTC-8),
// letting a legitimate replan get rejected near local midnight or letting a
// user exceed the daily cap by exploiting the drift.

/** The UTC offset, in milliseconds, that `timeZone` observes at `utcInstant`.
 * Positive for timezones ahead of UTC (e.g. Asia/Shanghai -> +8h). */
export function getTimezoneOffsetMs(timeZone, utcInstant) {
  const dtf = new Intl.DateTimeFormat("en-US", {
    timeZone,
    hourCycle: "h23",
    year: "numeric", month: "2-digit", day: "2-digit",
    hour: "2-digit", minute: "2-digit", second: "2-digit",
  });
  const parts = dtf.formatToParts(utcInstant);
  const map = {};
  for (const p of parts) if (p.type !== "literal") map[p.type] = p.value;
  // "24" shows up for midnight under some ICU implementations even with
  // h23; normalize it back to 0.
  const hour = Number(map.hour) === 24 ? 0 : Number(map.hour);
  const asUTC = Date.UTC(
    Number(map.year), Number(map.month) - 1, Number(map.day),
    hour, Number(map.minute), Number(map.second)
  );
  return asUTC - utcInstant.getTime();
}

/** Converts local midnight (00:00:00.000) of calendar date `dateStr`
 * (yyyy-MM-dd) in `timeZone` to the corresponding UTC instant. Handles
 * fractional-hour offsets (e.g. Asia/Kathmandu, +5:45) and DST transitions
 * via iterative refinement: the offset can only shift by a couple of hours
 * around a transition, so re-deriving it from an increasingly accurate guess
 * converges in a small, fixed number of steps. */
export function localMidnightToUtc(dateStr, timeZone) {
  const naiveUtc = new Date(`${dateStr}T00:00:00.000Z`).getTime();
  let guess = naiveUtc;
  for (let i = 0; i < 3; i++) {
    const offsetMs = getTimezoneOffsetMs(timeZone, new Date(guess));
    const next = naiveUtc - offsetMs;
    if (next === guess) break;
    guess = next;
  }
  return new Date(guess);
}

/** Adds `days` (may be negative) to a yyyy-MM-dd calendar date string using
 * pure UTC calendar arithmetic — no timezone involved, this is just date
 * math on the label itself (mirrors weekDatesFor's existing pattern). */
export function addDaysToDateString(dateStr, days) {
  const [year, month, day] = dateStr.split("-").map(Number);
  const d = new Date(Date.UTC(year, month - 1, day));
  d.setUTCDate(d.getUTCDate() + days);
  return d.toISOString().slice(0, 10);
}

/** The real UTC instant window [start, end) corresponding to one local
 * calendar day (`dateStr`) in `timeZone` — end is the following local
 * midnight, so callers get both a lower AND an upper bound instead of an
 * open-ended `gte` that silently absorbs the next day's events too. */
export function localDayUtcRange(dateStr, timeZone) {
  const start = localMidnightToUtc(dateStr, timeZone);
  const end = localMidnightToUtc(addDaysToDateString(dateStr, 1), timeZone);
  return { start, end };
}
