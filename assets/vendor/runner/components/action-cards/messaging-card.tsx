import { Textarea } from '@/components/ui/textarea'
import { useSync } from '@/hooks/primitives/useSync'
type ConversationDestination = {kind: 'channel' | 'dm' | 'group' | 'chat' | 'contact'; name: string | null}
type StagedWriteDestination = ConversationDestination
import { type Draft, setDraftField, useDraft } from './draft-store'
import { ExtraArgRows, ReadOnlyRow } from './fields'
import { useOverflowFade } from './scroll-fade'

const TARGET_ROWS = [
  { key: 'chat_id', label: 'Chat' },
  { key: 'chatId', label: 'Chat' },
  { key: 'contact_id', label: 'To' },
  { key: 'channelId', label: 'Channel' },
  { key: 'userId', label: 'To' },
  { key: 'userIds', label: 'To' },
  // An SMS names both phone numbers; `from` stays a reviewed row, not an extra arg.
  { key: 'to', label: 'To' },
  { key: 'from', label: 'From' },
] as const

// Chat tools stage the message as `text`; helpdesk replies (Intercom, Zendesk) stage `body`.
const BODY_KEYS = ['text', 'body'] as const

const MESSAGING_KEYS = [...TARGET_ROWS.map(({ key }) => key), ...BODY_KEYS]

function text(value: unknown): string {
  return typeof value === 'string' ? value : ''
}

/** The key this tool staged its message under; edits fold back to the same key. */
function bodyKey(args: Record<string, unknown>): (typeof BODY_KEYS)[number] {
  return BODY_KEYS.find((key) => typeof args[key] === 'string') ?? 'text'
}

function bodyText(args: Record<string, unknown>): string {
  return text(args[bodyKey(args)])
}

/** A destination arg is one id or, for a group DM, the list of them. */
function targetText(value: unknown): string {
  if (Array.isArray(value)) return value.filter((id) => typeof id === 'string').join(', ')
  return text(value)
}

export function foldMessagingDraft(args: Record<string, unknown>, draft: Draft): unknown {
  if (draft.text === undefined || draft.text === bodyText(args)) return undefined
  return { ...args, [bodyKey(args)]: draft.text }
}

// Mirrors each backend input schema so an over-limit edit fails here, not at
// dispatch after approval. Prefix matches survive a toolId version bump;
// `optional` marks a note where empty means "no note".
const TEXT_RULES: readonly {
  readonly toolPrefix: string
  readonly max: number
  readonly overflow: string
  readonly optional?: true
}[] = [
  {
    toolPrefix: 'twilio.send_sms@',
    max: 1600,
    overflow: 'An SMS body cannot exceed 1,600 characters.',
  },
  {
    toolPrefix: 'linkedin.send_invitation@',
    max: 200,
    overflow: 'A LinkedIn invitation note cannot exceed 200 characters.',
    optional: true,
  },
  {
    toolPrefix: 'linkedin.create_post@',
    max: 3000,
    overflow: 'A LinkedIn post cannot exceed 3,000 characters.',
  },
  {
    toolPrefix: 'linkedin.send_comment@',
    max: 1250,
    overflow: 'A LinkedIn comment cannot exceed 1,250 characters.',
  },
]

export function messagingDraftGate(
  args: Record<string, unknown>,
  draft: Draft,
  toolId: string,
): string | undefined {
  const message = (draft.text ?? bodyText(args)).trim()
  const rule = TEXT_RULES.find(({ toolPrefix }) => toolId.startsWith(toolPrefix))
  if (rule && message.length > rule.max) return rule.overflow
  if (rule?.optional) return undefined
  return message.length === 0 ? 'Message is empty.' : undefined
}

type Destination = ConversationDestination | StagedWriteDestination

/** The human form of a resolved destination: channels wear their hash, people and groups their name. */
function destinationDisplay(destination: Destination | undefined): string | null {
  if (destination === undefined || destination.name === null) return null
  return destination.kind === 'channel' ? `#${destination.name}` : destination.name
}

export function messagingSummary(
  args: Record<string, unknown>,
  draft: Draft,
  destination?: Destination,
): string | undefined {
  const target =
    destinationDisplay(destination) ??
    TARGET_ROWS.map(({ key }) => targetText(args[key])).find((value) => value !== '') ??
    ''
  const message = (draft.text ?? bodyText(args)).trim()
  const parts = [target, message].filter((part) => part !== '')
  return parts.length === 0 ? undefined : parts.join(' - ')
}

// A resolved row is labeled by what the destination IS, not by which arg carried it
// (a DM staged as a D… channel id would otherwise read "Channel: <person>").
const KIND_LABELS: Record<Destination['kind'], string> = {
  channel: 'Channel',
  dm: 'To',
  group: 'Group',
  chat: 'Chat',
  contact: 'To',
}

/** Destination rows; pinned above the scrolling body like the email recipients. */
export function MessagingTargetRows({
  args,
  destination,
}: {
  args: Record<string, unknown>
  destination?: Destination | undefined
}) {
  const display = destinationDisplay(destination)
  const rows = TARGET_ROWS.filter(({ key }) => targetText(args[key]) !== '')
  // The resolved name fronts the row; the staged id stays visible as the reviewed argument.
  const namedKey = display === null ? undefined : rows[0]?.key
  const namedLabel = destination === undefined ? undefined : KIND_LABELS[destination.kind]
  return (
    <div className="space-y-2">
      {rows.map(({ key, label }) => (
        <ReadOnlyRow
          key={key}
          label={key === namedKey && namedLabel !== undefined ? namedLabel : label}
          secondary={key === namedKey ? targetText(args[key]) : undefined}
          value={key === namedKey ? display : targetText(args[key])}
        />
      ))}
      {/* A write whose target is not a staged arg (an invitation id, say) still names who it concerns. */}
      {rows.length === 0 && display !== null && namedLabel !== undefined ? (
        <ReadOnlyRow label={namedLabel} value={display} />
      ) : null}
    </div>
  )
}

export function MessagingBody({
  args,
  commandId,
  editable,
  locked,
}: {
  args: Record<string, unknown>
  commandId: string
  editable: boolean
  locked: boolean
}) {
  const draft = useDraft(commandId)
  const message = draft.text ?? bodyText(args)
  // Fade the composer's edges only once the message overflows its scroll cap;
  // re-measured after commit on mount and on every message change.
  const fade = useOverflowFade<HTMLTextAreaElement>(12)
  useSync(message, fade.measure)
  return (
    <div className="space-y-2">
      {editable ? (
        <Textarea
          aria-label="Message"
          className="h-auto max-h-[180px] min-h-12 resize-none rounded-none border-0 bg-transparent px-0 py-0 font-sans text-ui-base leading-relaxed shadow-none focus-visible:border-0 focus-visible:ring-0 disabled:bg-transparent"
          disabled={locked}
          id={`${commandId}-text`}
          onChange={(event) => setDraftField(commandId, 'text', event.currentTarget.value)}
          placeholder="Write your message…"
          ref={fade.ref}
          style={fade.style}
          value={message}
        />
      ) : (
        <ReadOnlyRow label="Message" value={message} />
      )}
      <ExtraArgRows args={args} except={[...MESSAGING_KEYS, 'threadTs']} />
    </div>
  )
}
