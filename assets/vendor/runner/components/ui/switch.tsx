import { Switch as SwitchPrimitive } from '@base-ui/react/switch'

import { cn } from '@/lib/utils'

/**
 * The Runner switch: a Base UI switch styled as a small pill toggle. Checked
 * fills with the foreground color; the thumb slides right. Sized for settings
 * rows (matches the ui-* text scale).
 */
function Switch({ className, onCheckedChange, ...props }: SwitchPrimitive.Root.Props) {
  return (
    <SwitchPrimitive.Root
      data-slot="switch"
      className={cn(
        'inline-flex h-5 w-8 shrink-0 cursor-pointer items-center rounded-full bg-runner-foreground-20 p-0.5 outline-none transition-colors focus-visible:ring-1 focus-visible:ring-ring focus-visible:ring-offset-1 data-checked:bg-foreground data-disabled:cursor-not-allowed data-disabled:opacity-50',
        className,
      )}
      onCheckedChange={(checked, eventDetails) => {
        onCheckedChange?.(checked, eventDetails)
      }}
      {...props}
    >
      <SwitchPrimitive.Thumb
        data-slot="switch-thumb"
        className="size-4 rounded-full bg-background shadow-minimal transition-transform data-checked:translate-x-3"
      />
    </SwitchPrimitive.Root>
  )
}

export { Switch }
