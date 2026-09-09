// Extracted from Runner's FlueSessionTranscript.tsx. Only the presentation
// boundary changes: Maraithon's public WorkSummary replaces Flue tool payloads.
import type { ReactNode } from 'react'
import { ClockIcon, XCircleIcon } from 'lucide-react'
import { Marker, MarkerContent, MarkerIcon } from '@/components/ui/marker'
import { Spinner } from '@/components/ui/spinner'
import { Dialog, DialogTrigger, DialogContent, DialogHeader, DialogTitle, DialogDescription } from '@/components/ui/dialog'
import { Tooltip, TooltipContent, TooltipTrigger } from '@/components/ui/tooltip'
import { DetailRow } from './activity-details'
import { cn } from '@/lib/utils'

export type PublicToolCall = {
  id: string
  tool: string
  label: string
  status: string
  detail?: string
  summary?: string
  started_at?: string
  finished_at?: string
}

function statusLabel(status: string): string {
  return ({ running: 'Running', queued: 'Queued', completed: 'Completed', failed: 'Failed',
    cancelled: 'Cancelled', skipped: 'Skipped', pending: 'Pending' } as Record<string, string>)[status] ?? 'Unconfirmed'
}

function ToolTime({ value }: { value: string }) {
  const date = new Date(value)
  return <time dateTime={value}>{Number.isNaN(date.getTime()) ? value : new Intl.DateTimeFormat(undefined, {dateStyle: 'medium', timeStyle: 'medium'}).format(date)}</time>
}

export function SessionToolCall({ call, icon }: { call: PublicToolCall; icon: ReactNode }) {
  const running = call.status === 'running'
  const failed = call.status === 'failed'
  const waiting = call.status !== 'completed' && !running && !failed
  const markerContents = (
    <>
      <MarkerIcon>
        {running ? <Spinner className="motion-reduce:animate-none" /> : failed ? <XCircleIcon /> : waiting ? <ClockIcon /> : icon}
      </MarkerIcon>
      <MarkerContent className="flex min-w-0 flex-1 items-center gap-2">
        <span className="shrink-0 whitespace-nowrap text-runner-foreground-80">{call.label}</span>
        {(call.detail || call.summary) && (
          <span className={cn('min-w-0 flex-1 truncate text-runner-foreground-40', running && 'shimmer motion-reduce:shimmer-none')}>
            {call.detail || call.summary}
          </span>
        )}
        {failed && <ToolErrorChip text={call.summary ?? 'This check could not finish.'} />}
        {waiting && <span className="shrink-0 text-ui-xs">{statusLabel(call.status)}</span>}
      </MarkerContent>
    </>
  )
  return (
    <Dialog>
      <DialogTrigger render={
        <Marker className="cursor-pointer outline-none focus-visible:ring-1 focus-visible:ring-ring min-h-[44px] md:min-h-0"
          data-slot="tool-call" data-state={call.status}
          render={<button aria-label={`${call.label}, ${statusLabel(call.status).toLowerCase()}, view tool details`} type="button" />}
          aria-busy={running || undefined} />
      }>{markerContents}</DialogTrigger>
      <DialogContent className="grid-rows-[auto_minmax(0,1fr)] max-h-[min(42rem,calc(100dvh-2rem))] sm:max-w-2xl">
        <DialogHeader>
          <DialogTitle>{call.label}</DialogTitle>
          <DialogDescription>Context and outcome for this step.</DialogDescription>
        </DialogHeader>
        <div className="min-h-0 space-y-6 overflow-y-auto pr-3">
          <dl>
            <DetailRow label="Status" value={statusLabel(call.status)} />
            {call.started_at && <DetailRow label="Started" value={<ToolTime value={call.started_at} />} />}
            {call.finished_at && <DetailRow label="Finished" value={<ToolTime value={call.finished_at} />} />}
          </dl>
          {call.detail && <section><h3 className="mb-1 font-medium text-ui-sm">Context</h3><p className="text-ui-base wrap-break-word text-runner-foreground-70">{call.detail}</p></section>}
          <section>
            <h3 className="mb-1 font-medium text-ui-sm">{failed ? 'Error' : 'Result'}</h3>
            <p className={cn('text-ui-base wrap-break-word', failed ? 'text-destructive' : 'text-runner-foreground-70')}>
              {call.summary || (running ? 'This check is still running.' : waiting ? 'No confirmed result yet.' : 'The check completed.')}
            </p>
          </section>
        </div>
      </DialogContent>
    </Dialog>
  )
}

function ToolErrorChip({ text }: { text: string }) {
  return (
    <Tooltip>
      <TooltipTrigger render={<span className="shrink-0 rounded-ui-sm bg-runner-foreground-3 px-1.5 py-0.5 font-medium text-muted-foreground text-ui-sm shadow-minimal" />}>
        Error
      </TooltipTrigger>
      <TooltipContent className="max-w-sm" side="top">{text}</TooltipContent>
    </Tooltip>
  )
}
