import type { ReactNode } from 'react'
import { type Temporal, lexicalForm } from '@runner-next/time'
import { formatInstant } from '@/lib/time-format'

/** One label/value line in the summary list a transcript dialog opens with. */
export function DetailRow({ label, value }: { label: string; value: ReactNode }) {
  return (
    <div className="flex items-baseline justify-between gap-4 border-runner-border border-b py-1.5 last:border-b-0">
      <dt className="shrink-0 text-runner-foreground-50 text-ui-sm">{label}</dt>
      <dd className="min-w-0 break-all text-right font-medium font-mono text-runner-foreground text-ui-xs">
        {value}
      </dd>
    </div>
  )
}

/**
 * The one wall-clock format a transcript dialog uses, so the turn panel and the
 * activity rows one click away cannot disagree about the same instant. Seconds,
 * because the reason to read one of these is to line a step up against a
 * Logfire span, and a minute is not enough to do that.
 */
export function formatTranscriptTime(when: Temporal.Instant, timeZone: string): string {
  return formatInstant(when, { timeZone, dateStyle: 'medium', timeStyle: 'medium' })
}

/**
 * When the model step a transcript row belongs to started, in the viewer's
 * timezone. Every dialog an activity row opens draws this row, so clicking
 * Thinking, a skill activation, or a tool call answers "when" in the same place
 * and the same words.
 *
 * The label says STEP because that is what the reading dates — see
 * `messageTimestamp`. The rows of one step share it, so several rows can read
 * the same second, and each of them ran after it.
 */
export function ActivityTimeRow({ at }: { at: Temporal.Instant }) {
  const timeZone = Intl.DateTimeFormat().resolvedOptions().timeZone
  return (
    <DetailRow
      label="Step started"
      value={<time dateTime={lexicalForm(at)}>{formatTranscriptTime(at, timeZone)}</time>}
    />
  )
}
