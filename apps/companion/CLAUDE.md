# Claude Instructions — maraithon-mac

Follow `AGENTS.md` for engineering rules. Highlights for working in this
repo:

- This is a SwiftUI macOS app (macOS 14+) built with SwiftPM.
- Mirrors the server contracts in
  [`../maraithon`](../maraithon) — when you add or change an endpoint, do
  the server side first.
- Spec is authoritative:
  [`../maraithon/docs/superpowers/specs/2026-05-10-companion-desktop-app-design.md`](../maraithon/docs/superpowers/specs/2026-05-10-companion-desktop-app-design.md).
- Apple HIG rules in `AGENTS.md` are blocking — defer to platform
  primitives, no custom chrome.
- Logging goes through `EventLog`, never `print`.
- Privacy: redact PII (handles, message bodies) before logging.

## Build

```sh
swift build
swift test
swift run Maraithon
```

## When working on a feature

1. Read the spec for the relevant section.
2. Read the existing code in the area you're touching.
3. Make the smallest change that satisfies the ticket.
4. Add tests where the ticket calls for them.
5. Run `swift test`.
