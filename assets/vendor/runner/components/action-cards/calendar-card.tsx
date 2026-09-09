import { Temporal } from '@runner-next/time'
import type { ReactNode } from 'react'
import { Switch } from '@/components/ui/switch'
import { Label } from '@/components/ui/label'
import { formatInstant, formatPlainDate, formatPlainDateTime } from '@/lib/time-format'
import { type CalendarDraftField, calendarDraftEditor } from './calendar-draft'
import { type Draft, setDraftField, useDraft } from './draft-store'
import { FIELD_LABEL_CLASS, FieldRow, extraArgEntries, humanizeKey } from './fields'

const DATE_ONLY = /^\d{4}-\d{2}-\d{2}$/
const DAY_FORMAT = { weekday: 'long', month: 'long', day: 'numeric' } as const
const TIME_FORMAT = { hour: 'numeric', minute: '2-digit' } as const

/**
 * A calendar event's endpoints come in three shapes, and collapsing them onto
 * one path is how a day-shift bug gets written:
 *
 * - `2026-07-08` — an all-day event: a calendar DAY, not an instant. Parsed as
 *   `PlainDate`; putting it on the instant path renders the previous day for
 *   every viewer west of UTC.
 * - `2026-07-08T10:00:00` — a floating wall clock with no offset: "10 AM" is
 *   the answer for every reader. Parsed as `PlainDateTime`.
 * - `2026-07-08T10:00:00-07:00` / `…Z` — a real instant, rendered in
 *   `timeZone`.
 */
type EventEndpoint =
  | { readonly kind: 'day'; readonly date: Temporal.PlainDate }
  | { readonly kind: 'wall'; readonly at: Temporal.PlainDateTime }
  | { readonly kind: 'instant'; readonly at: Temporal.Instant }

function parseEndpoint(value: string): EventEndpoint | null {
  if (DATE_ONLY.test(value)) {
    const date = tryFrom(() => Temporal.PlainDate.from(value))
    return date === null ? null : { kind: 'day', date }
  }
  const instant = tryFrom(() => Temporal.Instant.from(value))
  if (instant !== null) return { kind: 'instant', at: instant }
  const wall = tryFrom(() => Temporal.PlainDateTime.from(value))
  return wall === null ? null : { kind: 'wall', at: wall }
}

function tryFrom<T>(parse: () => T): T | null {
  try {
    return parse()
  } catch {
    // cause-allow: an endpoint shape that does not parse is tried against the next shape; the parse error names nothing beyond "not this form"
    return null
  }
}

function endpointDay(endpoint: EventEndpoint, timeZone: string): string {
  if (endpoint.kind === 'day') return formatPlainDate(endpoint.date, DAY_FORMAT)
  if (endpoint.kind === 'wall') return formatPlainDateTime(endpoint.at, DAY_FORMAT)
  return formatInstant(endpoint.at, { ...DAY_FORMAT, timeZone })
}

function endpointTime(endpoint: EventEndpoint, timeZone: string): string {
  if (endpoint.kind === 'day') return ''
  if (endpoint.kind === 'wall') return formatPlainDateTime(endpoint.at, TIME_FORMAT)
  return formatInstant(endpoint.at, { ...TIME_FORMAT, timeZone })
}

/** The calendar date an endpoint falls on, for the "same day?" collapse. */
function endpointDate(endpoint: EventEndpoint, timeZone: string): Temporal.PlainDate | null {
  if (endpoint.kind === 'day') return endpoint.date
  if (endpoint.kind === 'wall') return endpoint.at.toPlainDate()
  return tryFrom(() => endpoint.at.toZonedDateTimeISO(timeZone).toPlainDate())
}

export function formatEventRange(start: string, end: string | undefined, timeZone: string): string {
  const startPoint = parseEndpoint(start)
  if (startPoint === null) return start
  if (startPoint.kind === 'day') {
    const endPoint = end !== undefined && DATE_ONLY.test(end) ? parseEndpoint(end) : null
    // All-day end dates are exclusive; fold back one calendar day for display.
    // Calendar-day arithmetic, not fixed-ms subtraction, which drifts across DST.
    const endDate = endPoint?.kind === 'day' ? endPoint.date.subtract({ days: 1 }) : startPoint.date
    const startDay = formatPlainDate(startPoint.date, DAY_FORMAT)
    if (Temporal.PlainDate.compare(endDate, startPoint.date) <= 0) return `${startDay} (all day)`
    return `${startDay} - ${formatPlainDate(endDate, DAY_FORMAT)} (all day)`
  }
  const startDay = endpointDay(startPoint, timeZone)
  const startTime = endpointTime(startPoint, timeZone)
  const endPoint = end === undefined ? null : parseEndpoint(end)
  if (endPoint === null) return `${startDay}, ${startTime}`
  const endTime = endpointTime(endPoint, timeZone)
  const startDate = endpointDate(startPoint, timeZone)
  const endDate = endpointDate(endPoint, timeZone)
  if (startDate && endDate && startDate.equals(endDate)) {
    return `${startDay}, ${startTime} - ${endTime}`
  }
  return `${startDay}, ${startTime} - ${endpointDay(endPoint, timeZone)}, ${endTime}`
}

export function formatTimezone(value: string | undefined): string {
  const trimmed = value?.trim()
  return trimmed ? trimmed.replace(/_/g, ' ') : 'Calendar default'
}

export function formatNotifications(value: string): string {
  if (value === '') return 'Calendar default'
  if (value === 'none') return 'Do not notify guests'
  if (value === 'externalOnly') return 'Notify external guests'
  return 'Notify all guests'
}

export function formatRecurrence(values: unknown, timeZone: string): string {
  if (!Array.isArray(values)) return ''
  return values
    .filter((value): value is string => typeof value === 'string' && value.trim() !== '')
    .map((value) => formatRecurrenceRule(value.trim(), timeZone))
    .join(', ')
}

function formatRecurrenceRule(rule: string, timeZone: string): string {
  const rrule = rule.startsWith('RRULE:') ? rule.slice('RRULE:'.length) : rule
  const parts = new Map(
    rrule
      .split(';')
      .map((part) => part.split('='))
      .filter(
        (part): part is [string, string] =>
          part.length === 2 && Boolean(part[0]) && Boolean(part[1]),
      )
      .map(([key, value]) => [key.toUpperCase(), value]),
  )
  const frequency = parts.get('FREQ')
  if (frequency === undefined) return rule
  const interval = Number(parts.get('INTERVAL') ?? '1')
  const cadence = recurrenceCadence(
    frequency,
    Number.isFinite(interval) && interval > 0 ? interval : 1,
  )
  if (cadence === undefined) return rule
  const count = Number(parts.get('COUNT'))
  const countText =
    Number.isFinite(count) && count > 0 ? `, ${count} ${count === 1 ? 'time' : 'times'}` : ''
  const until = parts.get('UNTIL')
  const untilText = until === undefined ? '' : `, until ${formatRruleUntil(until, timeZone)}`
  return `Repeats ${cadence}${countText}${untilText}`
}

const CADENCE_UNITS: Record<string, string> = {
  DAILY: 'day',
  WEEKLY: 'week',
  MONTHLY: 'month',
  YEARLY: 'year',
}

function recurrenceCadence(frequency: string, interval: number): string | undefined {
  const unit = CADENCE_UNITS[frequency]
  if (unit === undefined) return undefined
  if (interval === 1) return unit === 'day' ? 'daily' : `${unit}ly`
  return `every ${interval} ${unit}s`
}

const UNTIL_FORMAT = { month: 'short', day: 'numeric', year: 'numeric' } as const

function formatRruleUntil(value: string, timeZone: string): string {
  const match = value.match(/^(\d{4})(\d{2})(\d{2})(?:T(\d{2})(\d{2})(\d{2})Z?)?$/)
  if (!match) return value
  const [, year, month, day, hour, minute, second] = match
  // A date-only UNTIL is a calendar DAY, not an instant: putting it on the
  // instant path shifts it a day for every viewer west of UTC.
  if (hour === undefined) {
    const date = tryFrom(() => Temporal.PlainDate.from(`${year}-${month}-${day}`))
    return date === null ? value : formatPlainDate(date, UNTIL_FORMAT)
  }
  const at = tryFrom(() =>
    Temporal.Instant.from(`${year}-${month}-${day}T${hour}:${minute}:${second}Z`),
  )
  if (at === null) return value
  return formatInstant(at, { ...UNTIL_FORMAT, timeZone })
}

export function calendarSummary(
  toolId: string,
  args: Record<string, unknown>,
  draft: Draft,
): string | undefined {
  if (!toolId.includes('create_event')) return undefined
  const editor = calendarDraftEditor(toolId, args)
  const title =
    editor === undefined ? text(args.summary) || text(args.subject) : editor.values(draft).title
  return title.trim() === '' ? undefined : `Create event: ${title}`
}

function text(value: unknown): string {
  return typeof value === 'string' ? value : ''
}

function names(value: unknown): string[] {
  return Array.isArray(value) ? value.filter((entry) => typeof entry === 'string') : []
}

const CALENDAR_KEYS = [
  'summary',
  'subject',
  'start',
  'end',
  'timeZone',
  'location',
  'attendees',
  'addAttendees',
  'removeAttendees',
  'description',
  'body',
  'sendUpdates',
  'calendarId',
  'addMeetLink',
  'recurrence',
  'isOnlineMeeting',
]

// Desktop-app parity: label left in ink-50, value right-aligned in full ink.
function DetailRow({ label, value }: { label: string; value: string }) {
  return (
    <div className="grid grid-cols-[max-content_minmax(0,1fr)] items-start gap-4">
      <span className="shrink-0 text-muted-foreground">{label}</span>
      <span className="min-w-0 break-words text-right text-foreground">{value}</span>
    </div>
  )
}

// Hairline-divided review group; the first rendered group drops its divider.
function ReviewSection({ children }: { children: ReactNode }) {
  return (
    <section className="space-y-2 border-border/70 border-t pt-3 first:border-t-0 first:pt-0">
      {children}
    </section>
  )
}

// Desktop-app parity: guests read as initial-avatar chips, packed to the right.
function GuestsRow({ label, guests }: { label: string; guests: readonly string[] }) {
  return (
    <div className="grid grid-cols-[max-content_minmax(0,1fr)] items-start gap-4">
      <span className="shrink-0 text-muted-foreground">{label}</span>
      <div className="flex min-w-0 flex-wrap items-center justify-end gap-x-2 gap-y-1">
        {guests.map((guest, index) => (
          <span
            className="inline-flex min-w-0 items-center gap-1.5 text-foreground"
            key={`${guest}-${index}`}
          >
            <span className="inline-flex size-4 shrink-0 items-center justify-center rounded-full bg-runner-muted font-medium text-[9px] text-muted-foreground uppercase">
              {guest.trim() === '' ? '?' : guest.trim()[0]}
            </span>
            <span className="truncate">{guest}</span>
          </span>
        ))}
      </div>
    </div>
  )
}

// A borderless select row; the visible label doubles as the control's name.
function SelectRow({
  id,
  label,
  locked,
  onChange,
  options,
  value,
}: {
  id: string
  label: string
  locked: boolean
  onChange: (value: string) => void
  options: readonly { readonly value: string; readonly label: string }[]
  value: string
}) {
  return (
    <div className="grid grid-cols-[max-content_minmax(0,1fr)] items-center gap-4">
      <Label className={FIELD_LABEL_CLASS} htmlFor={id}>
        {label}
      </Label>
      <select
        className="min-w-0 border-0 bg-transparent p-0 text-right text-foreground text-ui-base outline-none disabled:opacity-50"
        disabled={locked}
        id={id}
        onChange={(event) => onChange(event.currentTarget.value)}
        value={value}
      >
        {options.map((option) => (
          <option key={option.value} value={option.value}>
            {option.label}
          </option>
        ))}
      </select>
    </div>
  )
}

function SwitchRow({
  checked,
  label,
  labelId,
  locked,
  onChange,
}: {
  checked: boolean
  label: string
  labelId: string
  locked: boolean
  onChange: (checked: boolean) => void
}) {
  return (
    <div className="grid grid-cols-[max-content_minmax(0,1fr)] items-center gap-4">
      <span className={FIELD_LABEL_CLASS} id={labelId}>
        {label}
      </span>
      <div className="flex justify-end">
        <Switch
          aria-labelledby={labelId}
          checked={checked}
          disabled={locked}
          onCheckedChange={onChange}
        />
      </div>
    </div>
  )
}

export function CalendarBody({
  args,
  commandId,
  connectedAccountLabel,
  editable,
  locked,
  timeZone,
  toolId,
}: {
  args: Record<string, unknown>
  commandId: string
  connectedAccountLabel?: string | undefined
  editable: boolean
  locked: boolean
  /** Instant-bearing endpoints read in this zone; all-day dates and offset-less
   * wall times are zone-independent by construction. */
  timeZone: string
  toolId: string
}) {
  const draft = useDraft(commandId)
  const editor = calendarDraftEditor(toolId, args)
  const values = editable && editor !== undefined ? editor.values(draft) : undefined
  const set = (field: CalendarDraftField, value: string) => setDraftField(commandId, field, value)
  const rowId = (field: CalendarDraftField) => `${commandId}-${field}`

  const heading = text(args.summary) || text(args.subject)
  const start = text(args.start)
  const isEvent = start !== ''
  const location = text(args.location)
  const description = text(args.description) || text(args.body)
  const sendUpdates = text(args.sendUpdates)
  const recurrence = formatRecurrence(args.recurrence, timeZone)
  const calendar = text(args.calendarId) || 'Primary'
  const account = connectedAccountLabel?.trim()
  const calendarDisplay = account && account !== calendar ? `${calendar} (${account})` : calendar
  const meetLink = typeof args.addMeetLink === 'boolean' ? args.addMeetLink : undefined
  const teamsMeeting = typeof args.isOnlineMeeting === 'boolean' ? args.isOnlineMeeting : undefined
  const guestRows = [
    { label: 'Guests', value: names(args.attendees) },
    { label: 'Add guests', value: names(args.addAttendees) },
    { label: 'Remove guests', value: names(args.removeAttendees) },
  ].filter((row) => row.value.length > 0)
  const showWho = guestRows.length > 0 || sendUpdates !== ''
  const extras = extraArgEntries(args, CALENDAR_KEYS)
  return (
    <div className="space-y-5 text-ui-base">
      {values === undefined ? (
        heading !== '' && (
          <h3 className="break-words font-medium text-ui-md leading-snug">{heading}</h3>
        )
      ) : (
        <FieldRow
          id={rowId('title')}
          label="Title"
          locked={locked}
          onChange={(value) => set('title', value)}
          placeholder="Event title"
          value={values.title}
        />
      )}
      <div className="space-y-4">
        {(isEvent || values !== undefined) && (
          <ReviewSection>
            {values === undefined ? (
              <>
                <DetailRow
                  label="When"
                  value={formatEventRange(start, text(args.end) || undefined, timeZone)}
                />
                <DetailRow
                  label="Timezone"
                  value={formatTimezone(text(args.timeZone) || undefined)}
                />
              </>
            ) : (
              <>
                <FieldRow
                  id={rowId('start')}
                  label="Start"
                  locked={locked}
                  onChange={(value) => set('start', value)}
                  step={values.dateOnly ? undefined : 1}
                  type={values.dateOnly ? 'date' : 'datetime-local'}
                  value={values.start}
                />
                <FieldRow
                  id={rowId('end')}
                  label="End"
                  locked={locked}
                  onChange={(value) => set('end', value)}
                  step={values.dateOnly ? undefined : 1}
                  type={values.dateOnly ? 'date' : 'datetime-local'}
                  value={values.end}
                />
                {values.dateOnly ? (
                  <DetailRow
                    label="Timezone"
                    value={formatTimezone(text(args.timeZone) || undefined)}
                  />
                ) : (
                  <FieldRow
                    id={rowId('timeZone')}
                    label="Timezone"
                    locked={locked}
                    onChange={(value) => set('timeZone', value)}
                    placeholder={values.timeZonePlaceholder}
                    value={values.timeZone}
                  />
                )}
              </>
            )}
            {recurrence !== '' && <DetailRow label="Repeats" value={recurrence} />}
          </ReviewSection>
        )}
        {(showWho || values !== undefined) && (
          <ReviewSection>
            {values === undefined ? (
              <>
                {guestRows.length > 0
                  ? guestRows.map((row) => (
                      <GuestsRow guests={row.value} key={row.label} label={row.label} />
                    ))
                  : isEvent && <DetailRow label="Guests" value="No guests" />}
                {sendUpdates !== '' && (
                  <DetailRow label="Notifications" value={formatNotifications(sendUpdates)} />
                )}
              </>
            ) : (
              <>
                <FieldRow
                  id={rowId('attendees')}
                  label="Guests"
                  locked={locked}
                  onChange={(value) => set('attendees', value)}
                  placeholder="guest@example.com, guest2@example.com"
                  value={values.attendees}
                />
                {values.notificationOptions.length > 0 && (
                  <SelectRow
                    id={rowId('notifications')}
                    label="Notifications"
                    locked={locked}
                    onChange={(value) => set('notifications', value)}
                    options={values.notificationOptions}
                    value={values.notifications}
                  />
                )}
              </>
            )}
          </ReviewSection>
        )}
        {(location !== '' ||
          meetLink !== undefined ||
          teamsMeeting !== undefined ||
          values !== undefined) && (
          <ReviewSection>
            {values === undefined ? (
              <>
                {location !== '' && <DetailRow label="Location" value={location} />}
                {meetLink !== undefined && (
                  <DetailRow
                    label="Google Meet"
                    value={meetLink ? 'Add Meet link' : 'No Meet link'}
                  />
                )}
                {teamsMeeting !== undefined && (
                  <DetailRow
                    label="Microsoft Teams"
                    value={teamsMeeting ? 'Add Teams link' : 'No Teams link'}
                  />
                )}
              </>
            ) : (
              <>
                <FieldRow
                  id={rowId('location')}
                  label="Location"
                  locked={locked}
                  onChange={(value) => set('location', value)}
                  placeholder="Add a location"
                  value={values.location}
                />
                <SwitchRow
                  checked={values.onlineMeeting}
                  label={values.onlineMeetingLabel}
                  labelId={rowId('onlineMeeting')}
                  locked={locked}
                  onChange={(checked) => set('onlineMeeting', checked ? 'true' : 'false')}
                />
              </>
            )}
          </ReviewSection>
        )}
        {typeof args.calendarId === 'string' && (
          <ReviewSection>
            <DetailRow label="Calendar" value={calendarDisplay} />
          </ReviewSection>
        )}
        {extras.length > 0 && (
          <ReviewSection>
            {extras.map(([key, value]) => (
              <DetailRow
                key={key}
                label={humanizeKey(key)}
                value={
                  typeof value === 'string'
                    ? value
                    : (JSON.stringify(value, null, 1) ?? String(value))
                }
              />
            ))}
          </ReviewSection>
        )}
        {values === undefined ? (
          description !== '' && (
            <ReviewSection>
              <h4 className="text-muted-foreground">Description</h4>
              <div className="whitespace-pre-wrap break-words text-foreground">{description}</div>
            </ReviewSection>
          )
        ) : (
          <ReviewSection>
            <FieldRow
              id={rowId('description')}
              label="Description"
              locked={locked}
              multiline
              onChange={(value) => set('description', value)}
              placeholder="Add a description"
              value={values.description}
            />
          </ReviewSection>
        )}
      </div>
    </div>
  )
}
