// Presentation adapter only. Data comes from AssistantProgress / MobileChatJSON;
// no Runner runtime, tool execution, or raw audit payloads cross this boundary.
import { useEffect, useState } from 'react'
import { createRoot, type Root } from 'react-dom/client'
import { flushSync } from 'react-dom'
import { CheckIcon, CopyIcon, MailIcon, CalendarIcon, MessageCircleIcon, FileTextIcon, UsersIcon, GlobeIcon, SearchIcon, ListTodoIcon, PenLineIcon, ClockIcon } from 'lucide-react'
import { Message, MessageContent, MessageHeader, MessageFooter } from '@/components/ui/message'
import { Bubble, BubbleContent } from '@/components/ui/bubble'
import { ActivityGroup } from '@/components/ui/activity-group'
import { Button } from '@/components/ui/button'
import { Tooltip, TooltipContent, TooltipTrigger } from '@/components/ui/tooltip'
import { MarkdownPreview } from '@/components/markdown/markdown-preview'
import { SessionToolCall, type PublicToolCall } from '@/routes/sessions/SessionToolCall'
import { WorkingIndicator } from '@/routes/sessions/WorkingIndicator'

type WorkSummary = { headline?: string; status?: string; summary?: string; preview?: string; tool_calls?: PublicToolCall[] }
type Turn = { id: string; role: string; body: string; sent_at?: string; work_summary?: WorkSummary }
type Run = { id: string; status: string; started_at?: string; work_summary?: WorkSummary }
type ConversationData = { message?: Turn; run?: Run; connected: boolean }
type Workspace = { el: HTMLElement; connected: boolean; runnerTurns?: Map<HTMLElement, {root: Root; serialized: string; connected: boolean}> }

function toolIcon(tool: string) {
  if (/gmail|email/.test(tool)) return <MailIcon />
  if (/calendar/.test(tool)) return <CalendarIcon />
  if (/messages|slack/.test(tool)) return <MessageCircleIcon />
  if (/people|relationship/.test(tool)) return <UsersIcon />
  if (/notes|files|memory/.test(tool)) return <FileTextIcon />
  if (/browser|web/.test(tool)) return <GlobeIcon />
  if (/draft|prepare/.test(tool)) return <PenLineIcon />
  if (/scheduled/.test(tool)) return <ClockIcon />
  if (/work|todo|open_loop/.test(tool)) return <ListTodoIcon />
  return <SearchIcon />
}

function Activity({ summary }: { summary?: WorkSummary }) {
  const calls = summary?.tool_calls ?? []
  if (!calls.length) return null
  const live = calls.find(call => call.status === 'running')
  const failed = calls.filter(call => call.status === 'failed').length
  const preview = live ? `${live.label}${live.detail ? ` · ${live.detail}` : ''}` :
    summary?.headline || `Supporting work${failed ? ` · ${failed} failed` : ''}`
  return <ActivityGroup count={calls.length} preview={preview}>
    {calls.map(call => <SessionToolCall key={call.id} call={call} icon={toolIcon(call.tool)} />)}
  </ActivityGroup>
}

function CopyResponse({ body }: { body: string }) {
  const [state, setState] = useState<'idle' | 'copied' | 'failed'>('idle')
  useEffect(() => {
    if (state === 'idle') return
    const timer = window.setTimeout(() => setState('idle'), 5000)
    return () => window.clearTimeout(timer)
  }, [state])
  const label = state === 'copied' ? 'Copied message' : state === 'failed' ? 'Could not copy. Try again.' : 'Copy message'
  return <Tooltip><TooltipTrigger render={
    <Button type="button" variant="tertiary" size="icon" className="size-6 text-runner-foreground-60" aria-label={label}
      onClick={async () => { try { await navigator.clipboard.writeText(body); setState('copied') } catch { setState('failed') } }} />
  }>{state === 'copied' ? <CheckIcon className="icon-sm" /> : <CopyIcon className="icon-sm" />}</TooltipTrigger>
    <TooltipContent>{label}</TooltipContent></Tooltip>
}

function Timestamp({ value }: { value?: string }) {
  if (!value) return null
  const date = new Date(value)
  if (Number.isNaN(date.getTime())) return null
  return <time dateTime={value} title={new Intl.DateTimeFormat(undefined, {dateStyle: 'medium', timeStyle: 'short'}).format(date)} className="text-runner-foreground-40 text-ui-xs">
    {new Intl.DateTimeFormat(undefined, {hour: 'numeric', minute: '2-digit'}).format(date)}
  </time>
}

function ConversationTurn({ message, run, connected }: ConversationData) {
  const user = message?.role === 'user'
  const summary = message?.work_summary || run?.work_summary
  const body = message?.body || summary?.preview || ''
  return <Message align={user ? 'end' : 'start'}><MessageContent>
    <MessageHeader className={user ? 'justify-end' : 'px-0'}>{user ? 'You' : 'Maraithon'}</MessageHeader>
    <Bubble variant={user ? 'primary' : 'secondary'}>
      <BubbleContent className={user ? 'max-h-[50dvh] overflow-y-auto' : 'w-full space-y-3'}>
        {!user && <Activity summary={summary} />}
        {body && (user ? <p className="whitespace-pre-wrap">{body}</p> : <MarkdownPreview mode={run ? 'streaming' : 'static'} isAnimating={!!run && connected}>{body}</MarkdownPreview>)}
        {run && (connected ? <WorkingIndicator key={run.id} since={run.started_at ? Date.parse(run.started_at) || undefined : undefined} label={summary?.headline || 'Working…'} /> : <p role="status" className="text-ui-sm text-muted-foreground">Reconnecting. Progress will resume here.</p>)}
      </BubbleContent>
    </Bubble>
    {message && <MessageFooter className="gap-2 px-0 pointer-fine:opacity-0 pointer-fine:transition-opacity pointer-fine:duration-150 pointer-fine:focus-within:opacity-100 pointer-fine:group-hover/message:opacity-100 motion-reduce:transition-none">
      {body && <CopyResponse body={body} />}<Timestamp value={message.sent_at} />
    </MessageFooter>}
  </MessageContent></Message>
}

export function renderRunnerConversation(workspace: Workspace) {
  workspace.runnerTurns ||= new Map()
  for (const [el, entry] of workspace.runnerTurns) {
    if (!workspace.el.contains(el)) { entry.root.unmount(); workspace.runnerTurns.delete(el) }
  }
  for (const el of workspace.el.querySelectorAll<HTMLElement>('[data-runner-turn]')) {
    const serialized = el.dataset.turn || '{}'
    const previous = workspace.runnerTurns.get(el)
    if (previous?.serialized === serialized && previous.connected === workspace.connected) continue
    const root = previous?.root || createRoot(el)
    // Finish before LiveView's timeline hook measures message heights. Stable roots
    // preserve activity disclosures and open detail dialogs across progress updates.
    flushSync(() => root.render(<ConversationTurn {...JSON.parse(serialized)} connected={workspace.connected} />))
    workspace.runnerTurns.set(el, {root, serialized, connected: workspace.connected})
  }
}

export function destroyRunnerConversation(workspace: Workspace) {
  for (const entry of workspace.runnerTurns?.values() ?? []) entry.root.unmount()
  workspace.runnerTurns?.clear()
}
