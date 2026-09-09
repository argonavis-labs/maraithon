// Pure height-clamp geometry for the expanded Action Card (desktop-app parity).
// The chrome measures the live anchor/boundary via the DOM and hands the
// resulting numbers here; this module never reads layout itself.

// Geometry of the expanded card's height clamp.
const CARD_MIN_HEIGHT_PX = 200 // minimum usable card height
const CARD_VIEWPORT_FRACTION = 0.8

/**
 * The expanded card's maxHeight. The card sits above the composer and grows
 * upward, so `anchorBottom` — its `getBoundingClientRect().bottom` — is the
 * stable anchor. `topBoundaryY` is the viewport y its top must not cross. Cap
 * to whichever is tighter, the room above the anchor or 80% of the viewport,
 * never below a usable floor.
 */
export function computeClampedCardHeight(
  anchorBottom: number,
  topBoundaryY: number,
  viewportHeight: number,
): number {
  const maxFromPosition = anchorBottom - topBoundaryY
  const maxFromViewport = viewportHeight * CARD_VIEWPORT_FRACTION
  return Math.max(CARD_MIN_HEIGHT_PX, Math.min(maxFromPosition, maxFromViewport))
}
