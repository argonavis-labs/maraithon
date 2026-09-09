import * as React from 'react'

import { cn } from '@/lib/utils'

function Textarea({ className, ...props }: React.ComponentProps<'textarea'>) {
  return (
    <textarea
      data-slot="textarea"
      className={cn(
        'flex field-sizing-content min-h-16 w-full rounded-ui-md border border-runner-foreground/15 bg-transparent px-2.5 py-2 text-ui-base transition-colors outline-none placeholder:text-muted-foreground focus-visible:border-runner-foreground/30 focus-visible:ring-1 focus-visible:ring-runner-foreground/30 disabled:cursor-not-allowed disabled:bg-runner-input/50 disabled:opacity-50 aria-invalid:border-destructive aria-invalid:ring-1 aria-invalid:ring-runner-destructive/20',
        className,
      )}
      {...props}
    />
  )
}

export { Textarea }
