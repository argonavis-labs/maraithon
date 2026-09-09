import { useState } from 'react'
import { Button } from '@/components/ui/button'
import { type Draft, setDraftField, useDraft } from './draft-store'
import { ExtraArgRows, FIELD_LABEL_CLASS, FieldRow, ReadOnlyRow } from './fields'
import { MarkdownField } from './markdown-field'

const EMAIL_KEYS = ['to', 'cc', 'bcc', 'subject', 'body'] as const
type EmailKey = (typeof EMAIL_KEYS)[number]
const EMAIL_FIELD_LABEL_CLASS = 'w-20'

function recipientsText(value: unknown): string {
  return Array.isArray(value) ? value.filter((entry) => typeof entry === 'string').join(', ') : ''
}

function text(value: unknown): string {
  return typeof value === 'string' ? value : ''
}

function parseRecipients(raw: string): string[] {
  return raw
    .split(',')
    .map((entry) => entry.trim())
    .filter((entry) => entry.length > 0)
}

function projection(args: Record<string, unknown>): Record<EmailKey, string> {
  return {
    to: recipientsText(args.to),
    cc: recipientsText(args.cc),
    bcc: recipientsText(args.bcc),
    subject: text(args.subject),
    body: text(args.body),
  }
}

export function foldEmailDraft(args: Record<string, unknown>, draft: Draft): unknown {
  const staged = projection(args)
  const dirty = EMAIL_KEYS.filter((key) => draft[key] !== undefined && draft[key] !== staged[key])
  if (dirty.length === 0) return undefined
  const revised: Record<string, unknown> = { ...args }
  for (const key of dirty) {
    const raw = draft[key] ?? ''
    if (key === 'subject' || key === 'body') {
      revised[key] = raw
      continue
    }
    const recipients = parseRecipients(raw)
    if (recipients.length === 0 && key !== 'to') delete revised[key]
    else revised[key] = recipients
  }
  return revised
}

export function emailDraftGate(args: Record<string, unknown>, draft: Draft): string | undefined {
  const to = draft.to ?? recipientsText(args.to)
  return parseRecipients(to).length === 0 ? 'Add at least one recipient.' : undefined
}

export function emailSummary(args: Record<string, unknown>, draft: Draft): string | undefined {
  const merged = { ...projection(args), ...draft }
  const parts = [merged.to, merged.subject].map((part) => part.trim()).filter((part) => part !== '')
  return parts.length === 0 ? undefined : parts.join(' - ')
}

/** Recipient and subject rows; pinned above the scrolling body so they track while it scrolls. */
export function EmailHeaderFields({
  args,
  commandId,
  editable,
  fromAddress,
  locked,
}: {
  args: Record<string, unknown>
  commandId: string
  editable: boolean
  // The connected account the mail is sent from; read-only, since the user can't switch it here.
  fromAddress?: string | undefined
  locked: boolean
}) {
  const draft = { ...projection(args), ...useDraft(commandId) }
  // A reply's recipient and subject stay bound to the thread the agent chose.
  const reply = args.replyToMessageId !== undefined
  const [revealed, setRevealed] = useState({ cc: false, bcc: false })
  // Desktop-app parity: recipients start folded into one summary line and
  // expand into editable rows on click (no way back, like the desktop card).
  const [recipientsExpanded, setRecipientsExpanded] = useState(false)
  const show = (key: 'cc' | 'bcc') => revealed[key] || draft[key] !== ''

  const placeholders: Partial<Record<EmailKey, string>> = {
    to: 'recipient@example.com',
    cc: 'cc@example.com',
    bcc: 'bcc@example.com',
    subject: 'Subject',
  }
  const field = (key: EmailKey, label: string) => (
    <FieldRow
      id={`${commandId}-${key}`}
      label={label}
      labelClassName={EMAIL_FIELD_LABEL_CLASS}
      locked={locked}
      onChange={(value) => setDraftField(commandId, key, value)}
      placeholder={placeholders[key]}
      value={draft[key]}
    />
  )

  const reveal = (key: 'cc' | 'bcc', label: string) => (
    <Button
      className="h-auto rounded-none border-0 p-0 font-normal text-muted-foreground text-ui-base hover:bg-transparent hover:text-foreground"
      disabled={locked}
      onClick={() => setRevealed((current) => ({ ...current, [key]: true }))}
      size="small"
      variant="tertiary"
    >
      {label}
    </Button>
  )
  // Desktop-app placement: Cc (and Bcc) reveal on the To row while Cc is
  // hidden; once Cc is visible the Bcc reveal moves onto the Cc row.
  const toToggles =
    editable && !show('cc') ? (
      <span className="ml-1 flex shrink-0 items-center gap-2">
        {reveal('cc', 'Cc')}
        {!show('bcc') && reveal('bcc', 'Bcc')}
      </span>
    ) : undefined
  const ccToggles =
    editable && !show('bcc') ? (
      <span className="ml-1 flex shrink-0 items-center gap-2">{reveal('bcc', 'Bcc')}</span>
    ) : undefined

  const recipientRows = recipientsExpanded ? (
    <>
      {editable && !reply ? (
        <FieldRow
          id={`${commandId}-to`}
          label="To"
          labelClassName={EMAIL_FIELD_LABEL_CLASS}
          locked={locked}
          onChange={(value) => setDraftField(commandId, 'to', value)}
          placeholder={placeholders.to}
          trailing={toToggles}
          value={draft.to}
        />
      ) : (
        <ReadOnlyRow
          label="To"
          labelClassName={EMAIL_FIELD_LABEL_CLASS}
          trailing={toToggles}
          value={draft.to}
        />
      )}
      {show('cc') &&
        (editable ? (
          <FieldRow
            id={`${commandId}-cc`}
            label="Cc"
            labelClassName={EMAIL_FIELD_LABEL_CLASS}
            locked={locked}
            onChange={(value) => setDraftField(commandId, 'cc', value)}
            placeholder={placeholders.cc}
            trailing={ccToggles}
            value={draft.cc}
          />
        ) : (
          draft.cc && (
            <ReadOnlyRow
              label="Cc"
              labelClassName={EMAIL_FIELD_LABEL_CLASS}
              trailing={ccToggles}
              value={draft.cc}
            />
          )
        ))}
      {show('bcc') &&
        (editable
          ? field('bcc', 'Bcc')
          : draft.bcc && (
              <ReadOnlyRow label="Bcc" labelClassName={EMAIL_FIELD_LABEL_CLASS} value={draft.bcc} />
            ))}
    </>
  ) : (
    <div className="flex items-center">
      <span className={`${FIELD_LABEL_CLASS} ${EMAIL_FIELD_LABEL_CLASS}`}>To</span>
      <button
        className="min-w-0 flex-1 border-0 bg-transparent p-0 text-left text-foreground text-ui-base outline-none"
        onClick={() => setRecipientsExpanded(true)}
        type="button"
      >
        {draft.to.trim() !== '' ? (
          <>
            {draft.to.trim()}
            {draft.cc.trim() !== '' && (
              <span className="text-muted-foreground">{`, Cc: ${draft.cc.trim()}`}</span>
            )}
            {draft.bcc.trim() !== '' && (
              <span className="text-muted-foreground">{`, Bcc: ${draft.bcc.trim()}`}</span>
            )}
          </>
        ) : (
          <span className="text-muted-foreground">Recipients</span>
        )}
      </button>
    </div>
  )

  return (
    <div className="space-y-2">
      {fromAddress !== undefined && fromAddress !== '' && (
        <ReadOnlyRow label="From" labelClassName={EMAIL_FIELD_LABEL_CLASS} value={fromAddress} />
      )}
      {recipientRows}
      {editable && !reply ? (
        field('subject', 'Subject')
      ) : (
        <ReadOnlyRow
          label="Subject"
          labelClassName={EMAIL_FIELD_LABEL_CLASS}
          value={draft.subject}
        />
      )}
    </div>
  )
}

export function EmailBody({
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
  const draft = { ...projection(args), ...useDraft(commandId) }
  return (
    <div className="space-y-4">
      {editable ? (
        <MarkdownField
          ariaLabel="Body"
          locked={locked}
          onChange={(markdown) => setDraftField(commandId, 'body', markdown)}
          placeholder="Write your message…"
          value={draft.body}
        />
      ) : (
        <ReadOnlyRow label="Body" value={draft.body} />
      )}
      <ExtraArgRows args={args} except={[...EMAIL_KEYS, 'replyToMessageId']} />
    </div>
  )
}
