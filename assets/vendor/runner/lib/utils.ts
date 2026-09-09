import { clsx, type ClassValue } from 'clsx'
import { extendTailwindMerge } from 'tailwind-merge'

// Teach tailwind-merge the Runner utilities declared in styles.css so a
// Runner size, radius, or shadow never collides with a color utility in the
// same group (e.g. `text-ui-base` and `text-muted-foreground` must both
// survive a merge; default tailwind-merge misreads `text-ui-*` as a color).
const twMerge = extendTailwindMerge<'icon-size'>({
  extend: {
    classGroups: {
      'font-size': [{ text: ['ui-xs', 'ui-sm', 'ui-base', 'ui-md', 'ui-lg'] }],
      rounded: [{ rounded: ['ui-sm', 'ui-md', 'ui-lg', 'ui-xl'] }],
      shadow: [{ shadow: ['thin', 'minimal', 'middle', 'strong'] }],
      'icon-size': [{ icon: ['xs', 'sm', 'base', 'md', 'lg'] }],
    },
  },
})

/** Combines conditional class values into one className, with later Tailwind classes winning conflicts. */
export function cn(...inputs: ClassValue[]) {
  return twMerge(clsx(inputs))
}
