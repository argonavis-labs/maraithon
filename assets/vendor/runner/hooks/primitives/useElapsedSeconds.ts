import { useEffect, useState } from 'react'

/**
 * Whole seconds elapsed since the anchor (epoch ms; defaults to mount), ticking
 * once per second.
 *
 * `now` is the caller's wall-clock reader in epoch milliseconds (`Platform.clock`
 * via `epochMillis`), passed in because generic UI never reaches the Platform
 * seam itself. It is wall-clock, not monotonic, on purpose: `since` is a
 * server-minted instant (a working lease's start), and only wall-clock time
 * shares an origin with it — a monotonic reader cannot be subtracted from a
 * server timestamp. The monotonic seam remains the right tool for a purely local
 * duration; a server-anchored one is a different question.
 */
export function useElapsedSeconds(since: number | undefined, now: () => number): number {
  const [elapsed, setElapsed] = useState(() =>
    since === undefined ? 0 : Math.max(0, Math.floor((now() - since) / 1000)),
  )

  useEffect(() => {
    const startedAt = since ?? now()
    const tick = () => setElapsed(Math.max(0, Math.floor((now() - startedAt) / 1000)))
    tick()
    const id = window.setInterval(tick, 1000)
    return () => window.clearInterval(id)
  }, [since, now])

  return elapsed
}
