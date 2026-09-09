import { ChevronRightIcon } from 'lucide-react'
import type * as React from 'react'
import { Collapsible, CollapsibleContent, CollapsibleTrigger } from '@/components/ui/collapsible'
import { cn } from '@/lib/utils'

const MAX_VISIBLE_ROWS = 15
const ROW_HEIGHT_PX = 24

/**
 * The transcript's agent-activity disclosure, ported from the Runner app:
 * a quiet header — rotating chevron, step-count chip, live preview line —
 * over an indented rail of activity rows. Collapsed by default; the preview
 * carries the running step's name while work is in flight and settles on a
 * summary when it finishes. Long runs scroll inside the rail instead of
 * swallowing the transcript.
 */
export function ActivityGroup({
  count,
  preview,
  defaultOpen = false,
  className,
  children,
}: {
  count: number
  preview: string
  defaultOpen?: boolean
  className?: string
  children: React.ReactNode
}) {
  return (
    // py-1 keeps the collapsed disclosure from sitting flush against the
    // prose blocks around it.
    <Collapsible
      className={cn('min-w-0 max-w-full py-1', className)}
      data-slot="activity-group"
      defaultOpen={defaultOpen}
    >
      <CollapsibleTrigger className="group/activity flex min-h-[44px] w-full md:min-h-0 select-none items-center gap-2 rounded-ui-lg py-1.5 text-left text-muted-foreground text-ui-base outline-none focus-visible:ring-1 focus-visible:ring-ring">
        <span aria-hidden className="flex icon-sm shrink-0 items-center justify-center">
          <ChevronRightIcon className="icon-sm transition-transform duration-150 group-aria-expanded/activity:rotate-90 motion-reduce:transition-none" />
        </span>
        <span className="-ml-0.5 shrink-0 rounded-ui-sm bg-background px-1.5 py-0.5 font-medium text-ui-sm shadow-minimal tabular-nums">
          {count}
        </span>
        <span className="relative flex h-5 min-w-0 flex-1 items-center">
          {/* Remounting on text change gives the Runner app's preview crossfade. */}
          <span
            className="absolute inset-0 animate-in truncate fade-in duration-200 motion-reduce:animate-none"
            key={preview}
          >
            {preview}
          </span>
        </span>
      </CollapsibleTrigger>
      <CollapsibleContent>
        <div
          className={cn(
            'ml-[5px] min-w-0 max-w-full space-y-0.5 border-runner-foreground-10 border-l pr-2 pl-3.5',
            // scroll-fade-y: the shared scroll-edge fade — rows dissolve at
            // the clipped edges and the fade retracts at either end of the
            // scroll range.
            count > MAX_VISIBLE_ROWS && 'scroll-fade-y overflow-y-auto py-1.5',
          )}
          style={
            count > MAX_VISIBLE_ROWS ? { maxHeight: MAX_VISIBLE_ROWS * ROW_HEIGHT_PX } : undefined
          }
        >
          {children}
        </div>
      </CollapsibleContent>
    </Collapsible>
  )
}
