import { Marker, MarkerContent, MarkerIcon } from '@/components/ui/marker'
import { Spinner } from '@/components/ui/spinner'
import { useElapsedSeconds } from '@/hooks/primitives/useElapsedSeconds'

/**
 * Liveness row shown for the whole time a run is in flight: a spinner and an
 * elapsed-seconds counter once the run is long enough to notice. It reflects
 * agent status alone — on while a run is in flight, off when idle — never the
 * shape of the streamed content, so it cannot flicker away mid-run while
 * activity is folded into a collapsed group. Distinct from SessionReasoning,
 * which renders model reasoning content, and from WaitingToContinueRail, which
 * announces a Session parked until its scheduled wake.
 */
export function WorkingIndicator({ since, label = "Working…" }: { since?: number; label?: string }) {
  // The anchor remains the existing Maraithon server timestamp.
  const elapsedSeconds = useElapsedSeconds(since, Date.now)

  return (
    <Marker data-testid="working-indicator" role="status">
      <MarkerIcon>
        <Spinner className="motion-reduce:animate-none" />
      </MarkerIcon>
      <MarkerContent className="shimmer motion-reduce:shimmer-none">
        {label}{elapsedSeconds > 0 ? ` ${elapsedSeconds}s` : ''}
      </MarkerContent>
    </Marker>
  )
}
