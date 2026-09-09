import { cn } from '@/lib/utils'

/**
 * The Runner spinner: a 3×3 cube grid sized in em so it matches the text
 * beside it, colored via currentColor. One size and one weight by design —
 * pass a text-* class to resize or recolor.
 */
function Spinner({ className, ...props }: React.ComponentProps<'output'>) {
  return (
    <output
      data-slot="spinner"
      aria-label="Loading"
      className={cn('cube-spinner text-runner-foreground-40', className)}
      {...props}
    >
      {CUBES.map((cube) => (
        <span key={cube} />
      ))}
    </output>
  )
}

const CUBES = [1, 2, 3, 4, 5, 6, 7, 8, 9]

export { Spinner }
