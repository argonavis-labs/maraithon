import * as React from 'react'
import { Input as InputPrimitive } from '@base-ui/react/input'

import { cn } from '@/lib/utils'

function Input({ className, type, ...props }: React.ComponentProps<'input'>) {
  return (
    <InputPrimitive
      type={type}
      data-slot="input"
      className={cn(
        'h-8 w-full min-w-0 rounded-ui-md border border-runner-foreground/15 bg-transparent px-2.5 py-1 text-ui-base transition-colors outline-none file:inline-flex file:h-6 file:border-0 file:bg-transparent file:font-medium file:text-foreground file:text-ui-sm placeholder:text-muted-foreground focus-visible:border-runner-foreground/30 focus-visible:ring-1 focus-visible:ring-runner-foreground/30 disabled:pointer-events-none disabled:cursor-not-allowed disabled:bg-runner-input/50 disabled:opacity-50 aria-invalid:border-destructive aria-invalid:ring-1 aria-invalid:ring-runner-destructive/20',
        className,
      )}
      {...props}
    />
  )
}

export { Input }
