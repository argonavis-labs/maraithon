import { Temporal } from '@runner-next/time'
import type { Draft } from './draft-store'

export type CalendarDraftField =
  | 'title'
  | 'start'
  | 'end'
  | 'timeZone'
  | 'attendees'
  | 'location'
  | 'description'
  | 'onlineMeeting'
  | 'notifications'

type NotificationOption = { readonly value: string; readonly label: string }

type CalendarDraftValues = {
  readonly title: string
  readonly start: string
  readonly end: string
  readonly timeZone: string
  readonly attendees: string
  readonly location: string
  readonly description: string
  readonly onlineMeeting: boolean
  readonly notifications: string
  readonly dateOnly: boolean
  readonly onlineMeetingLabel: string
  readonly notificationOptions: readonly NotificationOption[]
  readonly timeZonePlaceholder: string
}

type CalendarDraftEditor = {
  readonly values: (draft: Draft) => CalendarDraftValues
  readonly gate: (draft: Draft) => string | undefined
  readonly fold: (draft: Draft) => Record<string, unknown> | undefined
}

type Provider = {
  readonly titleArg: string
  readonly descriptionArg: string
  readonly onlineMeetingArg: string
  readonly onlineMeetingLabel: string
  readonly notificationsArg: string | undefined
  readonly notificationOptions: readonly NotificationOption[]
  readonly timeZonePlaceholder: string
  readonly allowsAllDay: boolean
  readonly titleMax: number | undefined
  readonly descriptionMax: number | undefined
  readonly locationMax: number | undefined
  readonly timeZoneMax: number | undefined
  readonly guestMax: number
  readonly guestAddressMax: number
}

const GOOGLE: Provider = {
  titleArg: 'summary',
  descriptionArg: 'description',
  onlineMeetingArg: 'addMeetLink',
  onlineMeetingLabel: 'Google Meet',
  notificationsArg: 'sendUpdates',
  notificationOptions: [
    { value: '', label: 'Calendar default' },
    { value: 'all', label: 'All guests' },
    { value: 'externalOnly', label: 'External guests' },
    { value: 'none', label: 'No guests' },
  ],
  timeZonePlaceholder: 'Calendar default',
  allowsAllDay: true,
  titleMax: 1024,
  descriptionMax: 8000,
  locationMax: 1024,
  timeZoneMax: 100,
  guestMax: 100,
  guestAddressMax: 320,
}

const OUTLOOK: Provider = {
  titleArg: 'subject',
  descriptionArg: 'body',
  onlineMeetingArg: 'isOnlineMeeting',
  onlineMeetingLabel: 'Microsoft Teams',
  notificationsArg: undefined,
  notificationOptions: [],
  timeZonePlaceholder: 'UTC',
  allowsAllDay: false,
  titleMax: undefined,
  descriptionMax: 100000,
  locationMax: undefined,
  timeZoneMax: undefined,
  guestMax: 50,
  guestAddressMax: 320,
}

function providerFor(toolId: string): Provider | undefined {
  if (toolId === 'google-calendar.create_event@1') return GOOGLE
  if (toolId === 'outlook.create_event@1') return OUTLOOK
  return undefined
}

const DATE_ONLY = /^\d{4}-\d{2}-\d{2}$/
// A datetime-local control emits minute precision; the connectors stage seconds.
const LOCAL_DATE_TIME = /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}(:\d{2}(\.\d{1,3})?)?$/

const FIELDS: readonly CalendarDraftField[] = [
  'title',
  'start',
  'end',
  'timeZone',
  'attendees',
  'location',
  'description',
  'onlineMeeting',
  'notifications',
]

function fieldsOf(provider: Provider): readonly CalendarDraftField[] {
  return provider.notificationsArg === undefined
    ? FIELDS.filter((field) => field !== 'notifications')
    : FIELDS
}

function text(value: unknown): string {
  return typeof value === 'string' ? value : ''
}

function parseAttendees(value: string): string[] {
  return value
    .split(',')
    .map((entry) => entry.trim())
    .filter((entry) => entry.length > 0)
}

function attendeesText(value: unknown): string {
  return Array.isArray(value)
    ? value.filter((entry): entry is string => typeof entry === 'string').join(', ')
    : ''
}

function tryFrom<T>(parse: () => T): T | undefined {
  try {
    return parse()
  } catch {
    // cause-allow: an unparsed control value is reported by the gate, not by this parse error
    return undefined
  }
}

// Shape first: Temporal accepts a plain date as a date-time and vice versa.
function plainDate(value: string): Temporal.PlainDate | undefined {
  return DATE_ONLY.test(value) ? tryFrom(() => Temporal.PlainDate.from(value)) : undefined
}

function plainDateTime(value: string): Temporal.PlainDateTime | undefined {
  return LOCAL_DATE_TIME.test(value) ? tryFrom(() => Temporal.PlainDateTime.from(value)) : undefined
}

function localDateTimeText(value: string): string | undefined {
  return plainDateTime(value)?.toString({ smallestUnit: 'second' })
}

/** All-day is a property of the STAGED start, so a partial edit cannot flip the form. */
function isAllDay(provider: Provider, args: Record<string, unknown>): boolean {
  return provider.allowsAllDay && DATE_ONLY.test(text(args.start))
}

/** Google stages an exclusive end; the form shows the last included day. */
function inclusiveEnd(start: string, end: string): string {
  const parsed = plainDate(end)
  if (parsed === undefined) return start
  const inclusive = parsed.subtract({ days: 1 })
  const from = plainDate(start)
  return from !== undefined && Temporal.PlainDate.compare(inclusive, from) < 0
    ? start
    : inclusive.toString()
}

type Projection = Readonly<Record<CalendarDraftField, string>>

function projection(provider: Provider, args: Record<string, unknown>): Projection {
  const start = text(args.start)
  const end = text(args.end)
  const notificationsArg = provider.notificationsArg
  return {
    title: text(args[provider.titleArg]),
    start,
    end: isAllDay(provider, args) ? inclusiveEnd(start, end) : end,
    timeZone: text(args.timeZone),
    attendees: attendeesText(args.attendees),
    location: text(args.location),
    description: text(args[provider.descriptionArg]),
    onlineMeeting: args[provider.onlineMeetingArg] === true ? 'true' : 'false',
    notifications: notificationsArg === undefined ? '' : text(args[notificationsArg]),
  }
}

function effective(provider: Provider, args: Record<string, unknown>, draft: Draft): Projection {
  const staged = projection(provider, args)
  const editable = fieldsOf(provider)
  const pick = (field: CalendarDraftField) =>
    editable.includes(field) ? (draft[field] ?? staged[field]) : staged[field]
  return {
    title: pick('title'),
    start: pick('start'),
    end: pick('end'),
    timeZone: pick('timeZone'),
    attendees: pick('attendees'),
    location: pick('location'),
    description: pick('description'),
    onlineMeeting: pick('onlineMeeting'),
    notifications: pick('notifications'),
  }
}

// Text is compared and sent trimmed, so the gate's idea of blank matches the fold's.
const TRIMMED: readonly CalendarDraftField[] = ['title', 'timeZone', 'location', 'description']

function normalized(
  field: CalendarDraftField,
  value: string,
  dateOnly: boolean,
): string | undefined {
  if (field === 'start' || field === 'end') {
    return dateOnly ? plainDate(value)?.toString() : localDateTimeText(value)
  }
  if (field === 'attendees') return parseAttendees(value).join('\n')
  return TRIMMED.includes(field) ? value.trim() : value
}

function dirtyFields(
  provider: Provider,
  args: Record<string, unknown>,
  draft: Draft,
): CalendarDraftField[] {
  const staged = projection(provider, args)
  const dateOnly = isAllDay(provider, args)
  return fieldsOf(provider).filter((field) => {
    const value = draft[field]
    if (value === undefined) return false
    const next = normalized(field, value, dateOnly)
    return next !== undefined && next !== normalized(field, staged[field], dateOnly)
  })
}

function valuesOf(
  provider: Provider,
  args: Record<string, unknown>,
  draft: Draft,
): CalendarDraftValues {
  const merged = effective(provider, args, draft)
  return {
    title: merged.title,
    start: merged.start,
    end: merged.end,
    timeZone: merged.timeZone,
    attendees: merged.attendees,
    location: merged.location,
    description: merged.description,
    onlineMeeting: merged.onlineMeeting === 'true',
    notifications: merged.notifications,
    dateOnly: isAllDay(provider, args),
    onlineMeetingLabel: provider.onlineMeetingLabel,
    notificationOptions: provider.notificationOptions,
    timeZonePlaceholder: provider.timeZonePlaceholder,
  }
}

function longerThan(value: string, limit: number | undefined): boolean {
  return limit !== undefined && value.length > limit
}

function endpointError(merged: Projection, dateOnly: boolean): string | undefined {
  if (dateOnly) {
    const start = plainDate(merged.start)
    const end = plainDate(merged.end)
    if (start === undefined) return 'Enter a valid start.'
    if (end === undefined) return 'Enter a valid end.'
    return Temporal.PlainDate.compare(end, start) < 0 ? 'End must be on or after start.' : undefined
  }
  const start = plainDateTime(merged.start)
  const end = plainDateTime(merged.end)
  if (start === undefined) return 'Enter a valid start.'
  if (end === undefined) return 'Enter a valid end.'
  return Temporal.PlainDateTime.compare(end, start) <= 0 ? 'End must be after start.' : undefined
}

function gateOf(
  provider: Provider,
  args: Record<string, unknown>,
  draft: Draft,
): string | undefined {
  const editable = fieldsOf(provider)
  const touched = (field: CalendarDraftField) =>
    editable.includes(field) && draft[field] !== undefined
  const merged = effective(provider, args, draft)

  if (touched('title')) {
    if (merged.title.trim() === '') return 'Add an event title.'
    if (longerThan(merged.title, provider.titleMax)) return 'Title is too long.'
  }
  if (touched('start') || touched('end')) {
    const invalid = endpointError(merged, isAllDay(provider, args))
    if (invalid !== undefined) return invalid
  }
  if (touched('timeZone')) {
    if (text(args.timeZone).trim() !== '' && merged.timeZone.trim() === '') {
      return 'Add a timezone.'
    }
    if (longerThan(merged.timeZone, provider.timeZoneMax)) return 'Timezone is too long.'
  }
  if (touched('location') && longerThan(merged.location, provider.locationMax)) {
    return 'Location is too long.'
  }
  if (touched('description') && longerThan(merged.description, provider.descriptionMax)) {
    return 'Description is too long.'
  }
  if (touched('attendees')) {
    const guests = parseAttendees(merged.attendees)
    if (guests.length > provider.guestMax) {
      return `Remove some guests (${provider.guestMax} maximum).`
    }
    if (guests.some((guest) => guest.length > provider.guestAddressMax)) {
      return 'A guest address is too long.'
    }
  }
  return undefined
}

/** Blank optional text removes its provider argument. */
function setOrDrop(revised: Record<string, unknown>, key: string, value: string) {
  const trimmed = value.trim()
  if (trimmed === '') delete revised[key]
  else revised[key] = trimmed
}

function foldOf(
  provider: Provider,
  args: Record<string, unknown>,
  draft: Draft,
): Record<string, unknown> | undefined {
  const dirty = dirtyFields(provider, args, draft)
  if (dirty.length === 0) return undefined
  const merged = effective(provider, args, draft)
  const dateOnly = isAllDay(provider, args)
  const revised: Record<string, unknown> = { ...args }
  for (const field of dirty) {
    switch (field) {
      case 'title':
        revised[provider.titleArg] = merged.title.trim()
        break
      case 'start': {
        const value = dateOnly
          ? plainDate(merged.start)?.toString()
          : localDateTimeText(merged.start)
        if (value !== undefined) revised.start = value
        break
      }
      case 'end': {
        const value = dateOnly
          ? plainDate(merged.end)?.add({ days: 1 }).toString()
          : localDateTimeText(merged.end)
        if (value !== undefined) revised.end = value
        break
      }
      case 'timeZone':
        setOrDrop(revised, 'timeZone', merged.timeZone)
        break
      case 'location':
        setOrDrop(revised, 'location', merged.location)
        break
      case 'description':
        setOrDrop(revised, provider.descriptionArg, merged.description)
        break
      case 'attendees': {
        const guests = parseAttendees(merged.attendees)
        if (guests.length === 0) delete revised.attendees
        else revised.attendees = guests
        break
      }
      case 'onlineMeeting':
        revised[provider.onlineMeetingArg] = merged.onlineMeeting === 'true'
        break
      case 'notifications': {
        const arg = provider.notificationsArg
        if (arg !== undefined) setOrDrop(revised, arg, merged.notifications)
        break
      }
    }
  }
  return revised
}

export function calendarDraftEditor(
  toolId: string,
  args: Record<string, unknown>,
): CalendarDraftEditor | undefined {
  const provider = providerFor(toolId)
  if (provider === undefined) return undefined
  return {
    values: (draft) => valuesOf(provider, args, draft),
    gate: (draft) => gateOf(provider, args, draft),
    fold: (draft) => foldOf(provider, args, draft),
  }
}

// property-exempt: adapter onto calendarDraftEditor, whose fold the round-trip property covers
export function foldCalendarDraft(
  args: Record<string, unknown>,
  draft: Draft,
  toolId: string,
): unknown {
  return calendarDraftEditor(toolId, args)?.fold(draft)
}

// property-exempt: adapter onto calendarDraftEditor, whose gate the table-driven tests cover
export function calendarDraftGate(
  args: Record<string, unknown>,
  draft: Draft,
  toolId: string,
): string | undefined {
  return calendarDraftEditor(toolId, args)?.gate(draft)
}
