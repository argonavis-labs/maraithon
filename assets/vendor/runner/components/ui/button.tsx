import { Button as ButtonPrimitive } from '@base-ui/react/button'
import { cva, type VariantProps } from 'class-variance-authority'

import { cn } from '@/lib/utils'

/**
 * The Runner button. Four variants (default, secondary, tertiary,
 * destructive) and two text sizes (default, small) plus their square icon
 * counterparts. Inline icons inherit the text color and are sized by the
 * icon-* scale step that matches the button's text size.
 */
const buttonVariants = cva(
  "group/button runner-touch-hitslop inline-flex shrink-0 items-center justify-center rounded-ui-md border border-transparent bg-clip-padding font-medium text-ui-base whitespace-nowrap transition-colors outline-none select-none focus-visible:border-ring focus-visible:ring-1 focus-visible:ring-ring active:not-aria-[haspopup]:translate-y-px disabled:pointer-events-none disabled:opacity-50 aria-invalid:border-destructive aria-invalid:ring-1 aria-invalid:ring-runner-destructive/20 [&_svg]:pointer-events-none [&_svg]:shrink-0 [&_svg:not([class*='size-']):not([class*='icon-'])]:icon-base",
  {
    variants: {
      variant: {
        default: 'bg-primary text-primary-foreground hover:bg-runner-foreground-90',
        secondary:
          'border-runner-foreground/15 bg-background hover:bg-runner-foreground-3 aria-expanded:bg-muted aria-expanded:text-foreground',
        tertiary:
          'hover:bg-runner-foreground-3 aria-expanded:bg-muted aria-expanded:text-foreground',
        destructive:
          'border-runner-foreground/15 bg-background text-destructive hover:bg-runner-foreground-3 aria-expanded:bg-muted aria-expanded:text-destructive focus-visible:border-runner-destructive/40 focus-visible:ring-runner-destructive/20',
      },
      size: {
        default:
          'h-8 gap-1.5 px-3 has-data-[icon=inline-end]:pr-2.5 has-data-[icon=inline-start]:pl-2.5',
        small:
          "h-6 gap-1 px-2 text-ui-sm has-data-[icon=inline-end]:pr-1.5 has-data-[icon=inline-start]:pl-1.5 [&_svg:not([class*='size-']):not([class*='icon-'])]:icon-sm",
        // The icon-md override outranks the base icon-base rule only because
        // icon-md is declared after icon-base in styles.css; a reorder there
        // would silently revert this. icon-small uses the base's icon-base.
        icon: "size-8 [&_svg:not([class*='size-']):not([class*='icon-'])]:icon-md",
        'icon-small': 'size-6',
      },
    },
    defaultVariants: {
      variant: 'default',
      size: 'default',
    },
  },
)

function Button({
  className,
  variant = 'default',
  size = 'default',
  ...props
}: ButtonPrimitive.Props & VariantProps<typeof buttonVariants>) {
  return (
    <ButtonPrimitive
      data-slot="button"
      className={cn(buttonVariants({ variant, size, className }))}
      {...props}
    />
  )
}

export { Button, buttonVariants }
