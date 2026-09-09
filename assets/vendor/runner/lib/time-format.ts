import { Temporal, epochMillis, tryParseInstant } from '@runner-next/time'

/**
 * The SOLE `Intl.DateTimeFormat` seam in the web client, by contract rather
 * than tidiness (RUN-5626).
 *
 * Two properties make that contract load-bearing:
 *
 * 1. **Temporal values must never reach native Intl.** `Temporal.Instant`
 *    defines `valueOf` to throw a `TypeError` by design, so
 *    `new Intl.DateTimeFormat(...).format(instant)` fails loudly instead of
 *    formatting. Every helper here converts to epoch milliseconds first (see
 *    `intlFormat`), which is the only value shape native Intl accepts. A
 *    caller that "simplifies" that hop away breaks at runtime, not at build.
 * 2. **A timestamp never silently renders in the wrong zone.** `formatInstant`
 *    requires an explicit `timeZone` — supplied by the viewer-zone seam
 *    (`Platform.timeZone()`) or by the domain object that owns a zone (an
 *    automation's configured schedule zone). There is no implicit
 *    browser-local default, because that default is exactly how a schedule
 *    preview came to disagree with its own zone label.
 *
 * Malformed input renders `UNKNOWN_TIME` rather than throwing: these values
 * arrive from durable rows and wires that predate the convention, and a
 * timestamp is never important enough to blank a page over.
 */

/** What every helper here renders when its input (or zone) cannot be used. */
export const UNKNOWN_TIME = '—'

/** Display options for a value that carries its own instant; the zone is required. */
export type ZonedFormatOptions = Omit<Intl.DateTimeFormatOptions, 'timeZone'> & {
  /** IANA zone to render in. Explicit by contract — there is no local default. */
  readonly timeZone: string
  /** BCP-47 locale; `undefined` means the runtime's own locale. */
  readonly locale?: string | undefined
}

/** Display options for a value that is already a wall-clock reading; a zone would be meaningless. */
export type CalendarFormatOptions = Omit<Intl.DateTimeFormatOptions, 'timeZone'> & {
  readonly locale?: string | undefined
}

/**
 * The one native-Intl call. Takes epoch MILLISECONDS, never a Temporal value:
 * Temporal's `valueOf` throws by design, so passing the object through would
 * be a runtime `TypeError` at every call site instead of a formatted string.
 */
function intlFormat(
  epochMs: number,
  locale: string | undefined,
  options: Intl.DateTimeFormatOptions,
): string {
  try {
    return new Intl.DateTimeFormat(locale, options).format(epochMs)
  } catch {
    // cause-allow: an Intl-unusable zone or option set is the outcome being probed; we degrade to UNKNOWN_TIME and the RangeError names nothing beyond "unsupported"
    return UNKNOWN_TIME
  }
}

/**
 * Lenient parse of a wire/durable timestamp to an `Instant`, or `null`.
 * The parse seam for callers that need the instant itself (arithmetic,
 * ordering) rather than a display string — parse once at the command/query
 * layer, per the Web Client Command Pattern.
 */
export function instantOrNull(raw: string | null | undefined): Temporal.Instant | null {
  if (raw === null || raw === undefined) return null
  return tryParseInstant(raw)
}

/** Relative-label steps, largest first; anything under a minute is "just now". */
const RELATIVE_UNITS: readonly { unit: Intl.RelativeTimeFormatUnit; seconds: number }[] = [
  { unit: 'year', seconds: 31_536_000 },
  { unit: 'month', seconds: 2_592_000 },
  { unit: 'week', seconds: 604_800 },
  { unit: 'day', seconds: 86_400 },
  { unit: 'hour', seconds: 3_600 },
  { unit: 'minute', seconds: 60 },
]

/**
 * How long ago an instant was, as a label ("3 hours ago"). Under a minute —
 * including a slightly future stamp, when the server's clock runs ahead of
 * this device — reads "just now" instead of a nonsensical "in 5 seconds".
 * `nowEpochMs` comes from the caller's clock seam (`Platform.clock` via
 * `epochMillis`); a zone is irrelevant to a duration.
 */
export function formatRelativeInstant(
  raw: string | Temporal.Instant,
  nowEpochMs: number,
  locale?: string,
): string {
  const instant = typeof raw === 'string' ? tryParseInstant(raw) : raw
  if (instant === null) return UNKNOWN_TIME
  const elapsedSeconds = Math.floor((nowEpochMs - epochMillis(instant)) / 1000)
  const step = RELATIVE_UNITS.find((candidate) => elapsedSeconds >= candidate.seconds)
  if (step === undefined) return 'just now'
  try {
    return new Intl.RelativeTimeFormat(locale, { numeric: 'always' }).format(
      -Math.floor(elapsedSeconds / step.seconds),
      step.unit,
    )
  } catch {
    // cause-allow: an Intl-unusable locale is the outcome being probed; we degrade to UNKNOWN_TIME and the RangeError names nothing beyond "unsupported"
    return UNKNOWN_TIME
  }
}

/** Renders an instant (wire string or parsed value) in an explicit zone. */
export function formatInstant(raw: string | Temporal.Instant, options: ZonedFormatOptions): string {
  const { locale, ...intlOptions } = options
  const instant = typeof raw === 'string' ? tryParseInstant(raw) : raw
  if (instant === null) return UNKNOWN_TIME
  return intlFormat(epochMillis(instant), locale, intlOptions)
}

/**
 * Renders a calendar day as itself. Zone-free by construction: an all-day
 * event or a `date` column names a day, not an instant, and putting it on the
 * instant path shifts it by one day for every viewer west of UTC.
 */
export function formatPlainDate(
  value: string | Temporal.PlainDate,
  options: CalendarFormatOptions,
): string {
  const { locale, ...intlOptions } = options
  const date = typeof value === 'string' ? tryPlainDate(value) : value
  if (date === null) return UNKNOWN_TIME
  // Pinned to UTC so the rendered fields are exactly the date's own fields;
  // any other zone would re-derive a day from an instant and could shift it.
  return intlFormat(date.toZonedDateTime('UTC').epochMilliseconds, locale, {
    ...intlOptions,
    timeZone: 'UTC',
  })
}

/**
 * Renders a floating wall-clock reading as written. For values that carry no
 * offset (a calendar event's `2026-07-08T10:00:00`), where "10:00" is the
 * answer regardless of who is reading it.
 */
export function formatPlainDateTime(
  value: string | Temporal.PlainDateTime,
  options: CalendarFormatOptions,
): string {
  const { locale, ...intlOptions } = options
  const wall = typeof value === 'string' ? tryPlainDateTime(value) : value
  if (wall === null) return UNKNOWN_TIME
  return intlFormat(wall.toZonedDateTime('UTC').epochMilliseconds, locale, {
    ...intlOptions,
    timeZone: 'UTC',
  })
}

function tryPlainDate(raw: string): Temporal.PlainDate | null {
  try {
    return Temporal.PlainDate.from(raw)
  } catch {
    // cause-allow: the total-parse contract IS the discarded cause — a display helper reports "unknown", it does not report why
    return null
  }
}

function tryPlainDateTime(raw: string): Temporal.PlainDateTime | null {
  try {
    return Temporal.PlainDateTime.from(raw)
  } catch {
    // cause-allow: the total-parse contract IS the discarded cause — a display helper reports "unknown", it does not report why
    return null
  }
}
