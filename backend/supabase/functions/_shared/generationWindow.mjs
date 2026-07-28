// Scheduling predicates for generate-weekly-plan: "is this user due right
// now, and for which week?". Pure calendar/timezone arithmetic — no I/O, no
// Deno-specific APIs — so the hourly cron's most safety-critical decision is
// unit-testable offline (backend/tests/generationWindow.test.mjs) instead of
// only observable a week at a time in production.
//
// Extracted from generate-weekly-plan/index.ts when the window predicate was
// found inverted; see that file's history and
// backend/tests/generationWindow.test.mjs for the regression this guards.

// `profiles.timezone` is a free-form varchar(64) with no CHECK constraint
// (20260318000001_schema.sql), so a buggy or older client can persist a value
// Intl does not recognize ("Asia/Shanghi", "GMT+8", ...). Intl.DateTimeFormat
// throws RangeError on those, and selectDueUsers / runInferenceSweep iterate
// profiles without a per-profile try/catch — so a single corrupt row would
// abort the entire hourly sweep with a 500 before most users were even
// looked at. Falling back to UTC keeps one bad row from starving everyone
// else, and mirrors both the caller's existing `profile.timezone || "UTC"`
// default and the cleanup migration's COALESCE-to-UTC guard.
// Exported because guarding only this module is NOT enough: once the window
// predicates stop throwing, a malformed profile flows *deeper* into the sweep
// (inferenceGateOpen -> localDayUtcRange in timezone.mjs) and throws there
// instead — same 500, just later. Callers must normalize at the profile
// boundary so every downstream timezone helper receives a resolved value.
const resolvedTimezones = new Map();

export function resolveTimezone(timezone) {
  if (!timezone) return "UTC";
  const cached = resolvedTimezones.get(timezone);
  if (cached !== undefined) return cached;

  let resolved;
  try {
    new Intl.DateTimeFormat("en-US", { timeZone: timezone });
    resolved = timezone;
  } catch {
    // Warn once per distinct bad value: silently treating a corrupt row as
    // UTC would generate that user's plans against the wrong clock forever
    // with nothing in the logs to explain it.
    console.warn(`generationWindow: unrecognized timezone ${JSON.stringify(timezone)}, falling back to UTC`);
    resolved = "UTC";
  }
  resolvedTimezones.set(timezone, resolved);
  return resolved;
}

/** The user's local ISO weekday (0 = Sunday .. 6 = Saturday) and hour (0-23)
 * at UTC instant `now`. Unrecognized timezones fall back to UTC. */
export function localWeekdayAndHour(timezone, now) {
  const tz = resolveTimezone(timezone);
  const weekdayShort = new Intl.DateTimeFormat("en-US", { timeZone: tz, weekday: "short" }).format(now);
  const hourStr = new Intl.DateTimeFormat("en-US", { timeZone: tz, hour: "numeric", hourCycle: "h23" }).format(now);
  const map = { Sun: 0, Mon: 1, Tue: 2, Wed: 3, Thu: 4, Fri: 5, Sat: 6 };
  return { weekday: map[weekdayShort] ?? 0, hour: parseInt(hourStr, 10) };
}

/**
 * Weekly generation window: the user's local Sunday evening, 20:00 through
 * 23:59, and nothing else (Phase 2 plan §2 "本地时间 ∈ 周日 20:00~次日", §8.2
 * "周日 20:00 后第一个整点"; ADR-001 "每周日晚…依据本周实际训练与编辑事件生成
 * 下一整周计划").
 *
 * The window MUST stay bounded to Sunday, because the target week is derived
 * from `now` (see nextMondayString): the moment local time rolls into Monday,
 * "next Monday" jumps a further seven days, so any Mon–Sat tick generates the
 * week-after-next off a week that has not been trained yet. It was previously
 * written `weekday !== 0 || hour >= 20` — the negation of the intended
 * condition — which made every plan get generated a full week early at Monday
 * 00:00 and turned the real Sunday 20:00 run into a permanent no-op.
 *
 * That wide window cannot be salvaged as a catch-up mechanism either:
 * install_generated_plan enforces C21 (never write the current or a past
 * week), so a Mon–Sat tick is structurally incapable of backfilling the week
 * it would be catching up on. The only legitimate catch-up is the remaining
 * hourly ticks of the same Sunday evening (20:00 / 21:00 / 22:00 / 23:00).
 */
export function isGenerationWindowOpen(timezone, now) {
  const { weekday, hour } = localWeekdayAndHour(timezone, now);
  return weekday === 0 && hour >= 20; // 0 = Sunday
}

/** Behavioral-inference window: local 21:00–22:59. Late enough that a genuine
 * training day would normally be logged by now, early enough to still leave the
 * user their evening. Deliberately narrow so the hourly cron fires inference at
 * most ~2 times per user per day; the per-day "already replanned" gate collapses
 * that to at most one actual run. */
export function isInferenceWindowOpen(timezone, now) {
  const { hour } = localWeekdayAndHour(timezone, now);
  return hour >= 21 && hour < 23;
}

/** The calendar date (yyyy-MM-dd) of the Monday starting the ISO week
 * immediately after `now`'s local week, in `timezone`. Purely calendar-date
 * arithmetic — the RPC independently recomputes this server-side (C21) so
 * any drift here is a missed generation, never an unsafe write. */
export function nextMondayString(timezone, now) {
  return addDays(thisMondayString(timezone, now), 7);
}

/** The calendar date (yyyy-MM-dd) of the Monday starting `now`'s OWN local
 * week (unlike nextMondayString, no +7 shift) — the current week's plan is
 * keyed by this date. Mirrors the RPC's own `date_trunc('week', ...)`
 * computation (C21/C31's "current week" independently re-derived). */
export function thisMondayString(timezone, now) {
  const { weekday } = localWeekdayAndHour(timezone, now);
  const daysSinceMonday = weekday === 0 ? 6 : weekday - 1;
  return addDays(localDateString(timezone, now), -daysSinceMonday);
}

/** `now`'s own calendar date (yyyy-MM-dd) in `timezone` — used to decide
 * which of the current week's days are still eligible for replan.
 * Unrecognized timezones fall back to UTC. */
export function localDateString(timezone, now) {
  const tz = resolveTimezone(timezone);
  return new Intl.DateTimeFormat("en-CA", { timeZone: tz, year: "numeric", month: "2-digit", day: "2-digit" }).format(now);
}

/** Calendar-label arithmetic on a yyyy-MM-dd string — no timezone involved. */
function addDays(dateStr, days) {
  const [year, month, day] = dateStr.split("-").map(Number);
  const d = new Date(Date.UTC(year, month - 1, day));
  d.setUTCDate(d.getUTCDate() + days);
  return d.toISOString().slice(0, 10);
}
