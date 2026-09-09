import type { LucideIcon } from 'lucide-react'
import { Button } from '@/components/ui/button'
import { cn } from '@/lib/utils'

/** One choice in a segmented control. */
export type SegmentedOption<T extends string> = Readonly<{
  value: T
  label: string
  icon?: LucideIcon
}>

/**
 * The Runner segmented control: a quiet foreground/3 track and one
 * bg-background + shadow-minimal pill on the pressed choice. The Files detail
 * pane (Preview / Source) and the dashboard tabs row draw the same control.
 */
export function SegmentedControl<T extends string>({
  className,
  label,
  onValueChange,
  options,
  value,
}: {
  readonly className?: string
  readonly label: string
  readonly onValueChange: (value: T) => void
  readonly options: readonly SegmentedOption<T>[]
  readonly value: T
}) {
  return (
    <div
      aria-label={label}
      className={cn(
        'inline-flex h-7 shrink-0 items-center rounded-ui-lg bg-runner-foreground/3 p-0.5',
        className,
      )}
      role="group"
    >
      {options.map((option) => {
        const pressed = option.value === value
        const Icon = option.icon
        return (
          <Button
            aria-pressed={pressed}
            className={cn(
              'h-6 rounded-ui-md border-0 px-2 font-normal',
              pressed && 'bg-background text-foreground shadow-minimal hover:bg-background',
            )}
            key={option.value}
            onClick={() => onValueChange(option.value)}
            size="small"
            variant="tertiary"
          >
            {Icon === undefined ? null : <Icon data-icon="inline-start" />}
            {option.label}
          </Button>
        )
      })}
    </div>
  )
}
