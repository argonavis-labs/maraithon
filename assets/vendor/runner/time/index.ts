import { Temporal } from 'temporal-polyfill'

// Twelve exports of this module are listed in `KNOWN_PURE_IMPORTS`
// (scripts/check-property-tests.mjs), which means the property-test checker
// treats a call to one of them as deterministic and keeps classifying the
// caller pure. Removing that determinism from any listed function silently
// widens what the checker calls pure across three packages. `systemClock` is
// the one export deliberately left off that list, because it reads
// `Temporal.Now`.

export { Temporal } from 'temporal-polyfill'

/**
 * A UTC instant serialized in the repo's lexical form: `Date#toISOString()`
 * byte-compatible, always exactly 3 fractional digits, always `Z`.
 */
export type IsoInstant = string & { readonly __isoInstant: unique symbol }

/**
 * Lexical serialization form (3 fractional digits). Byte-identical to legacy
 * `Date#toISOString()`, so outputs interleave and byte-order correctly with
 * existing stored timestamp strings (wire, DO SQLite TEXT).
 */
export function lexicalForm(instant: Temporal.Instant): IsoInstant {
  // SAFETY: toString with fractionalSecondDigits: 3 always yields
  // `YYYY-MM-DDTHH:MM:SS.mmmZ`, the exact shape the IsoInstant brand names.
  return instant.toString({ fractionalSecondDigits: 3 }) as IsoInstant
}

/**
 * Value serialization form (6 fractional digits), for Postgres `timestamptz`
 * parameters only, where microsecond precision is truth. Deliberately
 * unbranded: its output is a Postgres parameter form that must never be
 * compared or stored as a lexical timestamp.
 */
export function valueForm(instant: Temporal.Instant): string {
  return instant.toString({ fractionalSecondDigits: 6 })
}

/** How much of a failed input the error *message* carries; `received` keeps it all. */
const MESSAGE_RECEIVED_LIMIT = 128

/**
 * A string that could not be parsed as an instant. Timestamps are never
 * secrets, so `received` carries the full raw input; the message truncates it
 * because failed parses can be arbitrary boundary garbage headed for logs.
 */
export class InstantParseError extends Error {
  readonly received: string

  constructor(received: string, options?: { cause?: unknown }) {
    const shown =
      received.length > MESSAGE_RECEIVED_LIMIT
        ? `${received.slice(0, MESSAGE_RECEIVED_LIMIT)}…`
        : received
    super(`Not a parseable instant: ${shown}`, options)
    this.name = 'InstantParseError'
    this.received = received
  }
}

/**
 * Lenient instant parser: accepts both fixed forms and any valid ISO-8601
 * instant. The ISO grammar Temporal implements natively covers Postgres
 * `timestamptz` text output (`2026-07-06 00:15:00.123456+00`: space
 * separator, 0-6 trimmed fraction digits, offset `±HH` / `±HHMM` / `±HH:MM`),
 * which is why no special-case branch exists. Throws `InstantParseError`
 * (with the underlying failure as `cause`) on anything else; throwing-averse
 * callers use `tryParseInstant`.
 */
export function parseInstant(raw: string): Temporal.Instant {
  try {
    return Temporal.Instant.from(raw)
  } catch (error) {
    throw new InstantParseError(raw, { cause: error })
  }
}

/**
 * A string that could not be parsed as a calendar date. Mirrors
 * `InstantParseError`: dates are never secrets, so `received` carries the full
 * raw input; the message truncates it because failed parses can be arbitrary
 * boundary garbage headed for logs.
 */
export class PlainDateParseError extends Error {
  readonly received: string

  constructor(received: string, options?: { cause?: unknown }) {
    const shown =
      received.length > MESSAGE_RECEIVED_LIMIT
        ? `${received.slice(0, MESSAGE_RECEIVED_LIMIT)}…`
        : received
    super(`Not a parseable plain date: ${shown}`, options)
    this.name = 'PlainDateParseError'
    this.received = received
  }
}

/**
 * Parses an ISO-8601 calendar date (`YYYY-MM-DD`, the exact form Postgres
 * `date` emits; Temporal's grammar also tolerates a trailing time component,
 * which it drops). Throws `PlainDateParseError` (with the underlying failure
 * as `cause`) on anything else.
 */
export function parsePlainDate(raw: string): Temporal.PlainDate {
  try {
    return Temporal.PlainDate.from(raw)
  } catch (error) {
    throw new PlainDateParseError(raw, { cause: error })
  }
}

/** Total variant of `parseInstant`: returns `null` instead of throwing. */
export function tryParseInstant(raw: string): Temporal.Instant | null {
  try {
    return parseInstant(raw)
  } catch {
    // cause-allow: the total variant's contract IS the discarded cause —
    // callers that need the parse failure's identity call parseInstant.
    return null
  }
}

/**
 * Orders two instants: -1, 0, or 1. Exists because `Temporal.Instant` is an
 * object — `===` is reference identity and `<`/`>` throw at runtime (its
 * `valueOf` throws by design) — so all ordering goes through
 * `Temporal.Instant.compare`.
 */
export function compareInstant(a: Temporal.Instant, b: Temporal.Instant): -1 | 0 | 1 {
  return Temporal.Instant.compare(a, b)
}

/** The later of two instants (`a` when equal). */
export function maxInstant(a: Temporal.Instant, b: Temporal.Instant): Temporal.Instant {
  return compareInstant(a, b) >= 0 ? a : b
}

/** The earlier of two instants (`a` when equal). */
export function minInstant(a: Temporal.Instant, b: Temporal.Instant): Temporal.Instant {
  return compareInstant(a, b) <= 0 ? a : b
}

/** Elapsed-time duration factories; every unit is exact clock time, never calendar arithmetic. */
export const durations = Object.freeze({
  ofSeconds(n: number): Temporal.Duration {
    return Temporal.Duration.from({ seconds: n })
  },
  ofMinutes(n: number): Temporal.Duration {
    return Temporal.Duration.from({ minutes: n })
  },
  ofHours(n: number): Temporal.Duration {
    return Temporal.Duration.from({ hours: n })
  },
  /** 24h elapsed time, NOT calendar days. */
  ofDays(n: number): Temporal.Duration {
    return Temporal.Duration.from({ hours: n * 24 })
  },
})

/** The instant `d` after `i` in exact elapsed time. */
export function addDuration(i: Temporal.Instant, d: Temporal.Duration): Temporal.Instant {
  return i.add(d)
}

/** The instant `d` before `i` in exact elapsed time. */
export function subDuration(i: Temporal.Instant, d: Temporal.Duration): Temporal.Instant {
  return i.subtract(d)
}

/** Milliseconds since the Unix epoch, for seams that speak `number` (e.g. `Date`, alarms). */
export function epochMillis(i: Temporal.Instant): number {
  return i.epochMilliseconds
}

/** The instant at `ms` milliseconds since the Unix epoch. */
export function instantFromEpochMillis(ms: number): Temporal.Instant {
  return Temporal.Instant.fromEpochMilliseconds(ms)
}

/** The injection seam for "now": pass a `Clock`, never read ambient time in domain code. */
export type Clock = () => Temporal.Instant

/** The ONE ambient `Temporal.Now` read in the repo, by design. */
export const systemClock: Clock = () => Temporal.Now.instant()
