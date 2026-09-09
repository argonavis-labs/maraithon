import type { ComponentProps, ReactNode } from 'react'
import { badgeVariants } from '@/components/ui/badge'
import { Spinner } from '@/components/ui/spinner'
import { cn } from '@/lib/utils'

export type StatusBadgeTone = 'neutral' | 'caution' | 'info' | 'success' | 'destructive'

/** Tone classes for the icon and any state text a caller renders inside the badge. */
export const statusBadgeToneClass: Record<StatusBadgeTone, string> = {
  neutral: 'text-muted-foreground',
  caution: 'text-runner-caution-text',
  info: 'text-runner-accent',
  success: 'text-runner-success-text',
  destructive: 'text-runner-destructive-text',
}

/**
 * The one status pill: leading icon (or a spinner while busy), toned by state,
 * with caller-supplied content. Domain badges (skills, writes, tasks) map
 * their states onto this instead of drawing their own pill.
 */
export function StatusBadge({
  tone = 'neutral',
  busy = false,
  icon,
  className,
  children,
  ...props
}: ComponentProps<'span'> & {
  tone?: StatusBadgeTone
  busy?: boolean
  icon?: ReactNode
}) {
  return (
    <span
      className={cn(badgeVariants({ variant: 'secondary' }), 'max-w-full', className)}
      data-slot="status-badge"
      data-tone={tone}
      {...props}
    >
      <span
        aria-hidden
        className={cn(
          'inline-flex shrink-0 items-center [&>svg]:shrink-0 [&>svg]:icon-sm',
          statusBadgeToneClass[tone],
        )}
      >
        {busy ? <Spinner /> : icon}
      </span>
      {children}
    </span>
  )
}
