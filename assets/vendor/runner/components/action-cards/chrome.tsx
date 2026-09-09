import {
  CheckCircle2Icon,
  LoaderCircleIcon,
  Maximize2Icon,
  Minimize2Icon,
  TriangleAlertIcon,
  XIcon,
} from 'lucide-react'
import { type KeyboardEvent, type ReactNode, useRef } from 'react'
import { Button } from '@/components/ui/button'
import { Tooltip, TooltipContent, TooltipTrigger } from '@/components/ui/tooltip'
import { useEventListener } from '@/hooks/primitives/useEventListener'
import { useSync } from '@/hooks/primitives/useSync'
import { cn } from '@/lib/utils'
import { computeClampedCardHeight } from './expanded-card-height'

export type ActionCardChromeProps = {
  commandId: string
  icon: ReactNode
  // Summary line derived from live fields, so header and pill track edits.
  title: string
  badge?: ReactNode | undefined
  busy: boolean
  statusIcon?: 'succeeded' | 'failed' | 'blocked' | 'notice' | undefined
  faded: boolean
  // Dims and inert-locks the body while an action is in flight or settled.
  locked: boolean
  minimized?: boolean | undefined
  // The expanded dialog provides the available height.
  maximized?: boolean | undefined
  onToggleMaximize?: (() => void) | undefined
  onToggleMinimize?: (() => void) | undefined
  onDismiss?: (() => void) | undefined
  dismissLabel?: string | undefined
  pinnedHeader?: ReactNode | undefined
  footerStart?: ReactNode | undefined
  footerClassName?: string | undefined
  // Full-width failure feedback below the card controls, so errors never
  // displace editable fields or the primary action.
  errorBar?: ReactNode | undefined
  // Provenance is available on the expanded title without occupying the card.
  titleTooltip?: ReactNode | undefined
  primary?: { label: string; busyLabel: string; disabled: boolean; onClick: () => void } | undefined
  // Body scroll/padding override for bodies that own their own pinned regions
  // (e.g. conversation context + composer).
  bodyClassName?: string | undefined
  children: ReactNode
}

const SHELL = 'rounded-[10px] bg-background shadow-middle overflow-hidden'

/** The shared card shell: a collapsed pill or the expanded review card; bodies own their fields. */
export function ActionCardChrome(props: ActionCardChromeProps) {
  // Inline task cards scroll with the page. Cap their body against viewport height.
  const cardRef = useRef<HTMLDivElement>(null)
  const clampCardHeight = () => {
    const el = cardRef.current
    if (!el) return
    // The sidebar column owns the maximized card's height; no clamp applies.
    if (props.maximized) {
      el.style.maxHeight = ''
      return
    }
    el.style.maxHeight = `${computeClampedCardHeight(
      window.innerHeight,
      0,
      window.innerHeight,
    )}px`
  }
  useSync(props.minimized ?? false, clampCardHeight)
  useSync(props.maximized ?? false, clampCardHeight)
  useEventListener(globalThis.window, 'resize', clampCardHeight)

  if (props.minimized) return <MinimizedPill {...props} />

  const toggle = toggleHandlers(props.onToggleMinimize)
  return (
    <div
      className={cn(
        'flex w-full flex-col',
        props.maximized ? 'h-full bg-background' : cn('max-h-[80vh]', SHELL),
        props.faded && 'opacity-60',
      )}
      data-testid={`action-card-${props.commandId}`}
      data-action-card-id={props.commandId}
      ref={cardRef}
    >
      <div
        className={cn(
          'flex w-full items-center justify-between gap-2 py-2 pr-2 pl-4',
          toggle && 'cursor-pointer',
        )}
        aria-expanded={toggle ? true : undefined}
        {...toggle}
      >
        <div className="flex min-w-0 items-center gap-2">
          {props.icon}
          {props.titleTooltip ? (
            <Tooltip>
              <TooltipTrigger
                render={<p className="min-w-0 truncate font-medium text-ui-base leading-tight" />}
              >
                {props.title}
              </TooltipTrigger>
              <TooltipContent side="top">{props.titleTooltip}</TooltipContent>
            </Tooltip>
          ) : (
            <p className="min-w-0 truncate font-medium text-ui-base leading-tight">{props.title}</p>
          )}
        </div>
        <div className="flex shrink-0 items-center gap-1.5">
          {props.badge}
          {props.onToggleMaximize && (
            <MaximizeButton
              maximized={props.maximized ?? false}
              onToggle={props.onToggleMaximize}
            />
          )}
          {props.onDismiss && (
            <DismissButton
              className="size-7 rounded-ui-md"
              disabled={props.busy}
              iconClassName="icon-md"
              label={props.dismissLabel ?? 'Reject'}
              onDismiss={props.onDismiss}
            />
          )}
        </div>
      </div>

      {props.pinnedHeader && (
        <div className={cn('shrink-0 px-4 py-2', props.locked && 'opacity-80')}>
          {props.pinnedHeader}
        </div>
      )}

      <div
        className={cn(
          'min-h-0 flex-1 overflow-y-auto overflow-x-hidden px-4 py-3 [scrollbar-width:none] [&::-webkit-scrollbar]:hidden',
          props.bodyClassName,
          props.locked && 'opacity-80',
        )}
        data-action-card-body
      >
        {props.children}
      </div>

      {(props.footerStart || props.primary) && (
        <div
          className={cn(
            'flex items-center justify-end gap-3 px-4 pt-2 pb-4',
            props.footerClassName,
          )}
        >
          {props.footerStart && (
            <div className="flex min-w-0 items-center gap-2">{props.footerStart}</div>
          )}
          {props.primary && (
            <Button
              className="ml-auto text-ui-sm"
              disabled={props.primary.disabled}
              onClick={props.primary.onClick}
            >
              {props.busy && <LoaderCircleIcon aria-hidden className="icon-base animate-spin" />}
              {props.busy ? props.primary.busyLabel : props.primary.label}
            </Button>
          )}
        </div>
      )}
      {props.errorBar && (
        <div
          className="flex min-w-0 shrink-0 animate-in items-center gap-2 border-runner-destructive/15 border-t bg-runner-destructive-5 px-4 py-2 text-runner-destructive-text text-ui-sm fade-in slide-in-from-bottom-[2px] [animation-duration:var(--runner-motion-duration-fast)] [animation-timing-function:var(--runner-motion-ease-out)] motion-reduce:animate-none"
          data-testid="action-error-bar"
          role="alert"
        >
          {props.errorBar}
        </div>
      )}
    </div>
  )
}

function MinimizedPill(props: ActionCardChromeProps) {
  return (
    <div
      className={cn(
        'inline-flex w-[200px] min-w-[200px] max-w-[200px] cursor-pointer items-center gap-2 self-end px-3 py-2',
        SHELL,
        props.faded && 'opacity-60',
      )}
      data-testid={`action-card-${props.commandId}`}
      data-action-card-id={props.commandId}
      data-action-card-minimized
      aria-expanded={false}
      {...toggleHandlers(props.onToggleMinimize)}
    >
      {props.icon}
      <p className="min-w-0 flex-1 truncate text-left text-ui-base">{props.title}</p>
      <PillStatusIcon busy={props.busy} statusIcon={props.statusIcon} />
      {props.onDismiss && (
        <DismissButton
          className="size-6 rounded-ui-sm"
          disabled={props.busy}
          iconClassName="icon-base"
          label={props.dismissLabel ?? 'Reject'}
          onDismiss={props.onDismiss}
        />
      )}
    </div>
  )
}

function PillStatusIcon({
  busy,
  statusIcon,
}: {
  busy: boolean
  statusIcon: 'succeeded' | 'failed' | 'blocked' | 'notice' | undefined
}) {
  if (statusIcon === 'succeeded')
    return (
      <span aria-label="Succeeded" className="shrink-0 text-runner-success" role="img">
        <CheckCircle2Icon className="icon-base" />
      </span>
    )
  if (statusIcon === 'failed')
    return (
      <span aria-label="Failed" className="shrink-0 text-runner-destructive-text" role="img">
        <TriangleAlertIcon className="icon-base" />
      </span>
    )
  if (statusIcon === 'blocked')
    return (
      <span
        aria-label="Needs reconnect"
        className="shrink-0 text-runner-destructive-text"
        role="img"
      >
        <TriangleAlertIcon className="icon-base" />
      </span>
    )
  if (statusIcon === 'notice')
    return (
      <span aria-label="Needs attention" className="shrink-0 text-runner-caution-text" role="img">
        <TriangleAlertIcon className="icon-base" />
      </span>
    )
  if (busy)
    return (
      <span aria-label="Working" className="shrink-0 text-muted-foreground" role="img">
        <LoaderCircleIcon className="icon-base animate-spin" />
      </span>
    )
  return null
}

// role=button div (not <button>) so the dismiss <button> can nest inside the toggle surface.
function toggleHandlers(onToggleMinimize: (() => void) | undefined) {
  if (!onToggleMinimize) return undefined
  return {
    role: 'button' as const,
    tabIndex: 0,
    onClick: onToggleMinimize,
    onKeyDown: (event: KeyboardEvent) => {
      // Keydown on a nested button (dismiss, maximize) bubbles here; acting on
      // it would both swallow the button's native click and minimize instead.
      if (event.target !== event.currentTarget) return
      if (event.key === 'Enter' || event.key === ' ') {
        event.preventDefault()
        onToggleMinimize()
      }
    },
  }
}

// Lives inside the click-to-toggle header, so the click must not also minimize.
function MaximizeButton({ maximized, onToggle }: { maximized: boolean; onToggle: () => void }) {
  const Icon = maximized ? Minimize2Icon : Maximize2Icon
  return (
    <button
      aria-label={maximized ? 'Restore card size' : 'Expand card'}
      className="runner-touch-hitslop inline-flex size-7 shrink-0 items-center justify-center rounded-ui-md text-muted-foreground transition-colors hover:bg-runner-foreground/10 hover:text-foreground"
      onClick={(event) => {
        event.stopPropagation()
        onToggle()
      }}
      type="button"
    >
      <Icon aria-hidden className="icon-base" />
    </button>
  )
}

// Lives inside a click-to-toggle container, so the click must not also toggle.
function DismissButton({
  className,
  disabled,
  iconClassName,
  label,
  onDismiss,
}: {
  className: string
  disabled: boolean
  iconClassName: string
  label: string
  onDismiss: () => void
}) {
  return (
    <button
      aria-label={label}
      className={cn(
        'runner-touch-hitslop inline-flex shrink-0 items-center justify-center text-muted-foreground transition-colors hover:bg-runner-foreground/10 hover:text-foreground disabled:pointer-events-none disabled:opacity-40',
        className,
      )}
      disabled={disabled}
      onClick={(event) => {
        event.stopPropagation()
        onDismiss()
      }}
      type="button"
    >
      <XIcon aria-hidden className={iconClassName} />
    </button>
  )
}
