import { $convertFromMarkdownString, $convertToMarkdownString } from '@lexical/markdown'
import { AutoLinkPlugin } from '@lexical/react/LexicalAutoLinkPlugin'
import { CheckListPlugin } from '@lexical/react/LexicalCheckListPlugin'
import { LexicalComposer } from '@lexical/react/LexicalComposer'
import { useLexicalComposerContext } from '@lexical/react/LexicalComposerContext'
import { ContentEditable } from '@lexical/react/LexicalContentEditable'
import { LexicalErrorBoundary } from '@lexical/react/LexicalErrorBoundary'
import { HistoryPlugin } from '@lexical/react/LexicalHistoryPlugin'
import { LinkPlugin } from '@lexical/react/LexicalLinkPlugin'
import { ListPlugin } from '@lexical/react/LexicalListPlugin'
import { MarkdownShortcutPlugin } from '@lexical/react/LexicalMarkdownShortcutPlugin'
import { OnChangePlugin } from '@lexical/react/LexicalOnChangePlugin'
import { RichTextPlugin } from '@lexical/react/LexicalRichTextPlugin'
import { TabIndentationPlugin } from '@lexical/react/LexicalTabIndentationPlugin'
import { TablePlugin } from '@lexical/react/LexicalTablePlugin'
import { useRef, useState } from 'react'
import {
  EDITOR_NODES,
  MARKDOWN_TRANSFORMERS,
  URL_MATCHERS,
} from '@/components/markdown/markdown-editor-config'
import { markdownEditorTheme } from '@/components/markdown/markdown-editor-theme'
import { useSync } from '@/hooks/primitives/useSync'
import { cn } from '@/lib/utils'

function LockPlugin({ locked }: { locked: boolean }) {
  const [editor] = useLexicalComposerContext()
  useSync(locked, (value) => editor.setEditable(!value))
  return null
}

/** Markdown-backed rich text; formatting via Markdown shortcuts and native ⌘B/⌘I, no toolbar. */
export function MarkdownField({
  ariaLabel,
  compact,
  locked,
  onChange,
  placeholder,
  value,
}: {
  ariaLabel: string
  compact?: boolean | undefined
  locked: boolean
  onChange: (markdown: string) => void
  placeholder?: string | undefined
  value: string
}) {
  // Lexical reads initialConfig once on mount; the draft store carries later edits.
  const [initialConfig] = useState(() => ({
    namespace: 'action-card-markdown',
    nodes: EDITOR_NODES,
    editable: !locked,
    editorState: () => $convertFromMarkdownString(value, MARKDOWN_TRANSFORMERS),
    onError: (error: Error) => {
      throw error
    },
    theme: markdownEditorTheme,
  }))
  // Plugins normalize the seeded state during mount; those fires are not user edits.
  const initializing = useRef(true)
  useSync(true, () => {
    initializing.current = false
  })
  return (
    <LexicalComposer initialConfig={initialConfig}>
      <div className="relative overflow-x-hidden font-sans text-ui-base leading-relaxed">
        <RichTextPlugin
          contentEditable={
            <ContentEditable
              aria-label={ariaLabel}
              className={cn(
                'w-full break-words outline-none [&[contenteditable=false]]:cursor-not-allowed [&[contenteditable=false]]:opacity-50',
                compact ? 'min-h-16' : 'min-h-[100px]',
              )}
            />
          }
          placeholder={
            placeholder === undefined ? null : (
              <div className="pointer-events-none absolute top-0 left-0 text-muted-foreground/50 text-ui-base">
                {placeholder}
              </div>
            )
          }
          ErrorBoundary={LexicalErrorBoundary}
        />
      </div>
      <HistoryPlugin />
      <ListPlugin />
      <CheckListPlugin />
      <LinkPlugin />
      <AutoLinkPlugin matchers={URL_MATCHERS} />
      <TablePlugin hasCellBackgroundColor={false} hasCellMerge={false} hasHorizontalScroll />
      <TabIndentationPlugin />
      <MarkdownShortcutPlugin transformers={MARKDOWN_TRANSFORMERS} />
      <OnChangePlugin
        ignoreSelectionChange
        onChange={(state) => {
          if (initializing.current) return
          onChange(state.read(() => $convertToMarkdownString(MARKDOWN_TRANSFORMERS)))
        }}
      />
      <LockPlugin locked={locked} />
    </LexicalComposer>
  )
}
