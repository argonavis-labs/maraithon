import { type CSSProperties, useRef, useState } from 'react'

/** Vertical scroll-edge fade mask: content dissolves over `edgePx` at both clipped edges. */
// property-exempt: pure string template with no branches; a property test would restate the literal.
export function scrollFadeMask(edgePx: number): string {
  return `linear-gradient(to bottom, transparent 0px, black ${edgePx}px, black calc(100% - ${edgePx}px), transparent 100%)`
}

/**
 * Overflow-gated scroll fade for a capped composer region: attach `ref` and
 * `style` to the scroller and call `measure` whenever its content may have
 * changed. The fade appears only once content actually overflows the cap.
 */
export function useOverflowFade<T extends HTMLElement>(
  edgePx: number,
): { ref: React.RefObject<T | null>; style: CSSProperties | undefined; measure: () => void } {
  const ref = useRef<T>(null)
  const [overflowing, setOverflowing] = useState(false)
  const measure = () => {
    const el = ref.current
    if (!el) return
    setOverflowing((current) => {
      const next = el.scrollHeight > el.clientHeight + 1
      return current === next ? current : next
    })
  }
  const mask = scrollFadeMask(edgePx)
  return {
    ref,
    style: overflowing ? { WebkitMaskImage: mask, maskImage: mask } : undefined,
    measure,
  }
}
