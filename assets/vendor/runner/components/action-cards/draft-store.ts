import { useSyncExternalStore } from 'react'

/** Client-only field edits keyed by commandId; they survive remounts and evaporate on reload. */
export type Draft = Readonly<Record<string, string>>

const EMPTY: Draft = {}
const drafts = new Map<string, Draft>()
const listeners = new Set<() => void>()

function emit() {
  for (const listener of listeners) listener()
}

function subscribe(listener: () => void) {
  listeners.add(listener)
  return () => {
    listeners.delete(listener)
  }
}

export function draftFor(commandId: string): Draft {
  return drafts.get(commandId) ?? EMPTY
}

export function setDraftField(commandId: string, field: string, value: string) {
  drafts.set(commandId, { ...draftFor(commandId), [field]: value })
  emit()
}

export function clearDraft(commandId: string) {
  if (drafts.delete(commandId)) emit()
}

export function useDraft(commandId: string): Draft {
  return useSyncExternalStore(subscribe, () => draftFor(commandId))
}

/** True while any card holds unsaved field edits. */
export function useHasDrafts(): boolean {
  return useSyncExternalStore(subscribe, () => drafts.size > 0)
}

/** Test-only: empties the module store between files. */
export function resetDraftsForTest(): void {
  drafts.clear()
  listeners.clear()
}
