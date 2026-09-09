import { useEffect, useEffectEvent } from 'react'

/** Subscribes the latest handler to a DOM event while target is non-null; pass null to disable. */
export function useEventListener<K extends keyof WindowEventMap>(
  target: Window | null,
  event: K,
  handler: (event: WindowEventMap[K]) => void,
  options?: { capture?: boolean },
): void
export function useEventListener<K extends keyof DocumentEventMap>(
  target: Document | null,
  event: K,
  handler: (event: DocumentEventMap[K]) => void,
  options?: { capture?: boolean },
): void
export function useEventListener(
  target: EventTarget | null,
  event: string,
  handler: (event: Event) => void,
  options?: { capture?: boolean },
): void
export function useEventListener(
  target: EventTarget | null,
  event: string,
  handler: (event: Event) => void,
  options?: { capture?: boolean },
): void {
  const onEvent = useEffectEvent(handler)
  const capture = options?.capture ?? false
  useEffect(() => {
    if (!target) return
    const listener = (event: Event) => onEvent(event)
    target.addEventListener(event, listener, { capture })
    return () => target.removeEventListener(event, listener, { capture })
  }, [target, event, capture])
}
