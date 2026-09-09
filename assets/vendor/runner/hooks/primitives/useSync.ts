import { useEffect, useEffectEvent } from 'react'

/** Applies the rendered value to a non-React system after commit, on mount and on change; an optional returned cleanup runs before the next apply and on unmount. */
export function useSync<T>(value: T, apply: (value: T) => void | (() => void)): void {
  const applyEvent = useEffectEvent(apply)
  useEffect(() => {
    // Void-typed applies may still return a value; only a real function is a cleanup.
    const cleanup = applyEvent(value)
    return typeof cleanup === 'function' ? cleanup : undefined
  }, [value])
}
