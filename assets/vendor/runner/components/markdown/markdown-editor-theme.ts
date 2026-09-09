import type { EditorThemeClasses } from 'lexical'

/* Node→class map shared by the WYSIWYG markdown editors; restores what Tailwind
   preflight strips (bullets, quotes, headings), mirroring the desktop
   markdown-editor theme. */
export const markdownEditorTheme: EditorThemeClasses = {
  root: 'outline-none',
  paragraph: 'my-3 leading-relaxed first:mt-0',
  heading: {
    h1: 'mt-7 mb-4 font-bold font-sans text-[16px] first:mt-0',
    h2: 'mt-6 mb-3 font-sans font-semibold text-[16px] first:mt-0',
    h3: 'mt-5 mb-3 font-sans font-semibold text-[15px] first:mt-0',
    h4: 'mt-3 mb-1 font-semibold text-[14px] first:mt-0',
    h5: 'mt-3 mb-1 font-semibold text-[13px] first:mt-0',
    h6: 'mt-3 mb-1 font-medium text-[13px] text-muted-foreground first:mt-0',
  },
  list: {
    ul: 'my-3 list-disc space-y-1.5 ps-[16px] pe-2 marker:text-runner-foreground-50',
    ol: 'my-3 list-decimal space-y-1.5 pl-6 marker:text-runner-foreground-50',
    listitem: 'leading-relaxed',
    nested: { listitem: 'list-none before:!hidden after:!hidden' },
    checklist: '!ps-0 !ms-0 my-3 list-none space-y-1.5',
    listitemChecked:
      'relative ml-0 list-none pl-7 text-muted-foreground line-through outline-none before:absolute before:top-[3px] before:left-0 before:block before:h-4 before:w-4 before:cursor-pointer before:rounded-[3px] before:border before:border-primary/40 before:bg-primary/10 before:content-[""] after:-rotate-45 after:absolute after:top-[4px] after:left-[3px] after:h-[5px] after:w-[10px] after:border-primary/60 after:border-b-2 after:border-l-2 after:content-[""]',
    listitemUnchecked:
      'relative ml-0 list-none pl-7 outline-none before:absolute before:top-[3px] before:left-0 before:block before:h-4 before:w-4 before:cursor-pointer before:rounded-[3px] before:border before:border-runner-foreground/20 before:content-[""]',
  },
  link: 'cursor-pointer text-foreground underline decoration-runner-foreground/20 underline-offset-[3px] transition-colors duration-150 hover:decoration-runner-foreground',
  quote:
    'my-3 rounded-r-ui-md border-runner-foreground/30 border-l-4 bg-runner-muted/30 py-2 pr-3 pl-4',
  code: 'my-2 block overflow-x-auto rounded-ui-md bg-runner-foreground/[0.04] p-3 font-mono text-[13px]',
  text: {
    bold: 'font-semibold',
    italic: 'italic',
    underline: 'underline',
    strikethrough: 'text-muted-foreground line-through',
    code: 'rounded bg-runner-foreground/[0.06] px-1 py-0.5 font-mono text-[13px]',
  },
  table: 'min-w-max divide-y divide-runner-border',
  tableScrollableWrapper: 'my-4 overflow-x-auto rounded-ui-md border',
  tableRow: 'transition-colors hover:bg-runner-muted/30',
  tableCell:
    'whitespace-nowrap border-runner-border border-r px-4 py-3 text-ui-base last:border-r-0 [&_p]:my-0',
  tableCellHeader:
    'whitespace-nowrap border-runner-border border-r bg-runner-muted/50 px-4 py-3 text-left font-semibold text-ui-base last:border-r-0 [&_p]:my-0',
}
