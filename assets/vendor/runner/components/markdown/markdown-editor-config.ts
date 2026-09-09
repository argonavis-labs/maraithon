/** Lexical nodes, transformers, and URL matchers for the Markdown editors. */

import { CodeHighlightNode, CodeNode } from '@lexical/code'
import {
  $createAutoLinkNode,
  $isAutoLinkNode,
  AutoLinkNode,
  LinkNode,
} from '@lexical/link'
import { ListItemNode, ListNode } from '@lexical/list'
import {
  CHECK_LIST,
  type TextMatchTransformer,
  type Transformer,
  TRANSFORMERS as BUILT_IN_TRANSFORMERS,
} from '@lexical/markdown'
import { createLinkMatcherWithRegExp } from '@lexical/react/LexicalAutoLinkPlugin'
import { HeadingNode, QuoteNode } from '@lexical/rich-text'
import { TableCellNode, TableNode, TableRowNode } from '@lexical/table'
import { $createTextNode } from 'lexical'
import { TABLE } from './markdown-table-transformer'

const URL_REGEX = /https?:\/\/[^\s]+[^\s.,;:!?)\]]/
const NEVER_MATCHES = /$^/u

// Exported autolinks stay bare URLs; the LINK transformer would wrap them as
// [url](url), and plain-text export would backslash-escape `_`/`*` in them.
const BARE_URL: TextMatchTransformer = {
  dependencies: [AutoLinkNode],
  export: (node) => ($isAutoLinkNode(node) ? node.getTextContent() : null),
  importRegExp: URL_REGEX,
  regExp: NEVER_MATCHES,
  replace: (textNode, match) => {
    const url = match[0]
    const link = $createAutoLinkNode(url)
    link.append($createTextNode(url))
    textNode.replace(link)
  },
  type: 'text-match',
}

/**
 * All built-in transformers plus the GFM table transformer and the bare-URL
 * autolink round-trip. BARE_URL and CHECK_LIST must precede the built-ins
 * that would otherwise claim their syntax.
 */
export const MARKDOWN_TRANSFORMERS: Transformer[] = [
  BARE_URL,
  TABLE,
  CHECK_LIST,
  ...BUILT_IN_TRANSFORMERS,
]

const SHARED_EDITOR_NODES = [
  HeadingNode,
  QuoteNode,
  ListNode,
  ListItemNode,
  AutoLinkNode,
  CodeNode,
  CodeHighlightNode,
  TableNode,
  TableRowNode,
  TableCellNode,
]

/** Nodes registered on a normal Markdown editor. */
export const EDITOR_NODES = [...SHARED_EDITOR_NODES, LinkNode]

/**
 * AutoLinkPlugin matchers — the matched text is itself the full URL.
 * Auto-linking typed URLs is what keeps them intact through the markdown
 * round-trip: plain-text export escapes `_`/`*`, but an auto-linked URL is
 * serialized bare by BARE_URL instead.
 */
export const URL_MATCHERS = [createLinkMatcherWithRegExp(URL_REGEX)]
