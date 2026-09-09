import type { MultilineElementTransformer } from '@lexical/markdown'
import {
  $createTableCellNode,
  $createTableNode,
  $createTableRowNode,
  $isTableCellNode,
  $isTableNode,
  $isTableRowNode,
  TableCellHeaderStates,
  TableCellNode,
  TableNode,
  TableRowNode,
} from '@lexical/table'
import { $createParagraphNode, $createTextNode } from 'lexical'

function parsePipeRow(line: string): string[] {
  return line
    .replace(/^\|/, '')
    .replace(/\|$/, '')
    .split('|')
    .map((cell) => cell.trim())
}

function isSeparatorRow(line: string): boolean {
  return /^\|?(\s*:?-+:?\s*\|)+\s*:?-+:?\s*\|?$/.test(line.trim())
}

/** GFM pipe tables ↔ Lexical table nodes; import-only replace, header row emits a `| --- |` separator on export. */
export const TABLE: MultilineElementTransformer = {
  type: 'multiline-element',
  dependencies: [TableNode, TableRowNode, TableCellNode],
  regExpStart: /^\s*\|(.+)\|\s*$/,
  regExpEnd: {
    regExp: /^\s*(?!\|)/,
    optional: true,
  },

  replace(rootNode, _children, startMatch, _endMatch, linesInBetween, isImport) {
    if (!isImport || !linesInBetween) return false
    const allLines = [startMatch[0] ?? '', ...linesInBetween].filter((line) => line.trim() !== '')
    if (allLines.length < 2) return false
    const [headerLine, separatorLine] = allLines
    if (separatorLine === undefined || !isSeparatorRow(separatorLine)) return false
    const headerCells = parsePipeRow(headerLine ?? '')
    if (headerCells.length === 0) return false

    const table = $createTableNode()
    const headerRow = $createTableRowNode()
    for (const text of headerCells) {
      const cell = $createTableCellNode(TableCellHeaderStates.ROW)
      const paragraph = $createParagraphNode()
      paragraph.append($createTextNode(text))
      cell.append(paragraph)
      headerRow.append(cell)
    }
    table.append(headerRow)

    for (const line of allLines.slice(2)) {
      if (isSeparatorRow(line)) continue
      const cells = parsePipeRow(line)
      const row = $createTableRowNode()
      for (let column = 0; column < headerCells.length; column++) {
        const cell = $createTableCellNode(TableCellHeaderStates.NO_STATUS)
        const paragraph = $createParagraphNode()
        paragraph.append($createTextNode(cells[column] ?? ''))
        cell.append(paragraph)
        row.append(cell)
      }
      table.append(row)
    }

    rootNode.append(table)
    return true
  },

  export(node) {
    if (!$isTableNode(node)) return null
    const rows = node.getChildren().filter($isTableRowNode)
    if (rows.length === 0) return null

    const output: string[] = []
    rows.forEach((row, rowIndex) => {
      const cells = row.getChildren().filter($isTableCellNode)
      const texts = cells.map((cell) => cell.getTextContent().trim())
      output.push(`| ${texts.join(' | ')} |`)
      if (rowIndex === 0) output.push(`| ${cells.map(() => '---').join(' | ')} |`)
    })
    return output.join('\n')
  },
}
