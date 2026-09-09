import {createRoot, type Root} from 'react-dom/client'
import {useEffect, useState} from 'react'
import {CalendarDaysIcon, CheckCircle2Icon, CopyIcon, ExternalLinkIcon, TriangleAlertIcon} from 'lucide-react'
import {ActionCardChrome} from '@/components/action-cards/chrome'
import {EmailHeaderFields, EmailBody, emailDraftGate, emailSummary} from '@/components/action-cards/email-card'
import {MessagingBody, MessagingTargetRows, messagingDraftGate, messagingSummary} from '@/components/action-cards/messaging-card'
import {CalendarBody} from '@/components/action-cards/calendar-card'
import {ReadOnlyRow} from '@/components/action-cards/fields'
import {clearDraft, draftFor, setDraftField, useDraft} from '@/components/action-cards/draft-store'
import {Button} from '@/components/ui/button'
import {StatusBadge, type StatusBadgeTone} from '@/components/ui/status-badge'
import {TooltipProvider} from '@/components/ui/tooltip'
import {Dialog, DialogContent, DialogTitle} from '@/components/ui/dialog'

// Runner renders the components. This adapter only maps Maraithon's existing draft contract.
type Card = Record<string, any>
type Props = {card: Card; editable: boolean; busy: boolean; messageId: string; logo?: string; providerLabel: string}
type Workspace = {
  el: HTMLElement; key: string; connected: boolean
  saved: {drafts: Record<string, Record<string, string>>; expanded: Record<string, boolean>}
  persist: () => void
  ask: (body: string) => void
  pushEvent: (event: string, payload: unknown, callback: () => void) => void
  runnerCards?: Map<HTMLElement, {root: Root; key: string}>
}
const TERMINAL = new Set(['Completed', 'Running', 'Saving', 'Could not complete', 'Sent', 'Saved to calendar', 'Cancelled', 'Expired', 'Sending', 'Could not send', 'Check before retrying'])
function safeLink(value: unknown): value is string {
  if (typeof value !== 'string') return false
  try { return ['https:', 'http:'].includes(new URL(value, window.location.origin).protocol) } catch { return false }
}
function projection(card: Card) {
  return card.provider === 'gmail'
    ? {to: card.recipient || '', cc: card.cc || '', bcc: card.bcc || '', subject: card.subject || '', body: card.body || ''}
    : {to: card.recipient || '', body: card.body || ''}
}
function fields(card: Card, key: string) {
  const draft = draftFor(key)
  return {recipient: draft.to ?? card.recipient ?? '', subject: draft.subject ?? card.subject ?? '',
    cc: draft.cc ?? card.cc ?? '', bcc: draft.bcc ?? card.bcc ?? '',
    body: (card.provider === 'gmail' ? draft.body : draft.text) ?? card.body ?? ''}
}
function tone(card: Card): StatusBadgeTone {
  if (['Sent', 'Completed', 'Saved to calendar'].includes(card.status)) return 'success'
  if (['Could not send', 'Could not complete'].includes(card.status)) return 'destructive'
  if (card.connection_required || card.status === 'Check before retrying') return 'caution'
  return 'neutral'
}
function CardReview({props, workspace, element, storeKey}: {props: Props; workspace: Workspace; element: HTMLElement; storeKey: string}) {
  const {card, messageId, providerLabel, editable} = props
  const draft = useDraft(storeKey)
  const [minimized, setMinimized] = useState(workspace.saved.expanded[element.id] === undefined ? element !== workspace.el.querySelector('[aria-label="Action reviews"] [data-runner-card]') : !workspace.saved.expanded[element.id])
  const [expanded, setExpanded] = useState(false)
  const [submitting, setSubmitting] = useState(false)
  const [feedback, setFeedback] = useState('')
  const terminal = TERMINAL.has(card.status)
  const busy = props.busy || submitting
  const locked = busy || !workspace.connected
  const args = projection(card)
  const messaging = ['slack', 'imessage'].includes(card.provider)
  const gate = card.provider === 'gmail' ? emailDraftGate(args, draft) : messaging ? messagingDraftGate(args, draft, '') : undefined
  const summary = card.provider === 'gmail' ? emailSummary(args, draft) : messaging ? messagingSummary(args, draft) : card.title
  const badgeTone = tone(card)
  useEffect(() => {
    if (editable) workspace.saved.drafts[messageId] = fields(card, storeKey)
    else delete workspace.saved.drafts[messageId]
    workspace.persist()
  }, [draft, editable])
  useEffect(() => {
    const open = () => {setMinimized(false); workspace.saved.expanded[element.id] = true; workspace.persist()}
    element.addEventListener('runner:expand', open)
    return () => element.removeEventListener('runner:expand', open)
  }, [])
  const toggleMinimize = () => {
    workspace.saved.expanded[element.id] = minimized
    workspace.persist()
    setMinimized(!minimized)
  }
  const decide = (decision: 'confirm' | 'reject') => {
    if (locked || terminal || !card.prepared_action_id || (decision === 'confirm' && (gate || card.connection_required))) return
    setSubmitting(true)
    workspace.pushEvent('workspace_decide', {action_id: card.prepared_action_id, decision,
      draft_edits: card.provider === 'browser' ? {} : fields(card, storeKey)}, () => setSubmitting(false))
  }
  const prepareEmail = () => {
    if (locked || terminal || gate || card.connection_required) return
    const f = fields(card, storeKey)
    workspace.ask(`Save this reviewed email as a Gmail draft and prepare its approval card. Do not send. Keep the original thread context. From: ${card.from || 'the source account'}\nTo: ${f.recipient}\nSubject: ${f.subject}\nCc: ${f.cc}\nBcc: ${f.bcc}\n\n${f.body}`)
  }
  const copy = async () => {
    try {await navigator.clipboard.writeText(fields(card, storeKey).body); setFeedback('Copied')}
    catch {setFeedback('Select the message and copy it with your browser.')}
  }
  const openMessages = () => {
    const f = fields(card, storeKey)
    if (!/^(\+?[0-9]{7,15}|[^\s<>@]+@[^\s<>@]+\.[^\s<>@]+)$/.test(f.recipient)) {
      setFeedback('A verified Messages address is needed. You can copy the draft.'); return
    }
    const separator = /iPad|iPhone|iPod/.test(navigator.userAgent) ? '&' : '?'
    window.location.href = `sms:${encodeURIComponent(f.recipient)}${separator}body=${encodeURIComponent(f.body)}`
    setFeedback('Review and send in Messages. Opening Messages does not confirm delivery.')
  }
  const primary = terminal ? undefined : card.prepared_action_id ? {
    label: card.send_label || 'Approve action', busyLabel: 'Working…', disabled: locked || !!gate || !!card.connection_required, onClick: () => decide('confirm')
  } : card.provider === 'gmail' && editable ? {
    label: 'Prepare to send', busyLabel: 'Preparing…', disabled: locked || !!gate || !!card.connection_required, onClick: prepareEmail
  } : card.provider === 'imessage' ? {
    label: 'Open in Messages', busyLabel: 'Opening…', disabled: locked || !!gate, onClick: openMessages
  } : undefined
  const renderCard = (maximized: boolean) => <ActionCardChrome
    commandId={messageId} title={summary || card.title || providerLabel}
    titleTooltip={<span>{card.title || providerLabel}{card.from ? ` · ${card.from}` : ''}</span>}
    icon={props.logo ? <img src={props.logo} alt={providerLabel} className="size-4 shrink-0 object-contain" /> : <CalendarDaysIcon aria-label={providerLabel} className="icon-md" />}
    badge={<StatusBadge tone={badgeTone} busy={busy} icon={badgeTone === 'success' ? <CheckCircle2Icon /> : card.connection_required ? <TriangleAlertIcon /> : undefined}>{card.status || 'Review draft'}</StatusBadge>}
    busy={busy} locked={locked || !editable} faded={badgeTone === 'success'}
    minimized={maximized ? false : minimized} maximized={maximized}
    onToggleMinimize={maximized ? undefined : toggleMinimize}
    onToggleMaximize={() => setExpanded(!expanded)}
    onDismiss={!terminal && card.prepared_action_id && !locked ? () => decide('reject') : undefined}
    dismissLabel="Cancel action" primary={primary}
    pinnedHeader={card.provider === 'gmail' ? <EmailHeaderFields args={args} commandId={storeKey} editable={editable} fromAddress={card.from} locked={locked} /> : messaging ? <MessagingTargetRows args={args} /> : card.from ? <ReadOnlyRow label="Account" value={card.from} /> : undefined}
    footerClassName="border-t border-border flex-wrap gap-y-2"
    footerStart={<>
      {card.body && <Button aria-label="Copy draft" size="small" variant="tertiary" onClick={copy}><CopyIcon />Copy</Button>}
      {safeLink(card.open_url) && <Button render={<a href={card.open_url} target="_blank" rel="noopener noreferrer" />} size="small" variant="tertiary"><ExternalLinkIcon />{card.open_label || 'Open source'}</Button>}
    </>}
    errorBar={!workspace.connected ? <span>Reconnecting… Your draft is kept.</span> : gate && editable && !terminal ? <span>{gate}</span> : card.connection_required ? <span>{card.connection_notice || 'Reconnect this account to continue.'}{safeLink(card.connection_url) && <a className="ml-2 underline" href={card.connection_url} target="_blank" rel="noopener noreferrer">{card.connection_label || 'Reconnect'}</a>}</span> : undefined}
  >
    {card.provider === 'gmail' ? <EmailBody args={args} commandId={storeKey} editable={editable} locked={locked} />
      : messaging ? <MessagingBody args={args} commandId={storeKey} editable={editable} locked={locked} />
      : card.provider === 'calendar' ? <CalendarBody args={{summary: card.title, description: card.body, start: card.start_at, end: card.end_at, timeZone: card.timezone || Intl.DateTimeFormat().resolvedOptions().timeZone}} commandId={storeKey} editable={false} locked={locked} timeZone={card.timezone || Intl.DateTimeFormat().resolvedOptions().timeZone} toolId="maraithon.calendar.review" />
      : <div className="space-y-3">
        {card.subject && <ReadOnlyRow label="Title" value={card.subject} />}
        {card.start_at && <ReadOnlyRow label="Starts" value={card.start_at} />}
        {card.end_at && <ReadOnlyRow label="Ends" value={card.end_at} />}
        {card.body && <ReadOnlyRow label={card.provider === 'calendar' ? 'Details' : 'Action'} value={card.body} />}
      </div>}
    {feedback && <p className="mt-3 text-ui-sm text-muted-foreground" role="status">{feedback}</p>}
  </ActionCardChrome>
  return <TooltipProvider>
    {!expanded && renderCard(false)}
    <Dialog open={expanded} onOpenChange={setExpanded}>
      <DialogContent showCloseButton={false} className="flex h-[min(85dvh,900px)] w-[min(900px,calc(100vw-2rem))] max-w-none flex-col gap-0 overflow-hidden p-0 sm:max-w-none">
        <DialogTitle className="sr-only">{card.title || providerLabel}</DialogTitle>
        {renderCard(true)}
      </DialogContent>
    </Dialog>
  </TooltipProvider>
}

export function renderRunnerCards(workspace: Workspace) {
  workspace.runnerCards ||= new Map()
  for (const [element, entry] of workspace.runnerCards) {
    if (!workspace.el.contains(element)) {entry.root.unmount(); clearDraft(entry.key); workspace.runnerCards.delete(element)}
  }
  for (const element of workspace.el.querySelectorAll<HTMLElement>('[data-runner-card]')) {
    const props: Props = JSON.parse(element.dataset.card || '{}')
    let entry = workspace.runnerCards.get(element)
    if (!entry) {
      const key = `${workspace.key}:${props.messageId}`
      const saved = workspace.saved.drafts[props.messageId]
      if (saved && props.editable) {
        for (const [name, value] of Object.entries(saved)) setDraftField(key, name === 'recipient' ? 'to' : name === 'body' && props.card.provider !== 'gmail' ? 'text' : name, value)
      }
      element.replaceChildren()
      entry = {root: createRoot(element), key}
      workspace.runnerCards.set(element, entry)
    }
    if (!props.editable) clearDraft(entry.key)
    entry.root.render(<CardReview props={props} workspace={workspace} element={element} storeKey={entry.key} />)
  }
}
export function destroyRunnerCards(workspace: Workspace) {
  for (const entry of workspace.runnerCards?.values() || []) {entry.root.unmount(); clearDraft(entry.key)}
  workspace.runnerCards?.clear()
}
