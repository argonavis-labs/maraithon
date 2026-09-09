# Runner components in Maraithon

This directory contains source copied from `runner-next`, at the commit recorded in `source-manifest.json`. The manifest records each original file's SHA-256 hash. It also identifies the time helper copied from `packages/time`.

The task workspace renders these React components in Phoenix LiveView. Both the web app and Electron use the same bundle. `assets/js/runner-cards.tsx` maps Maraithon's existing public draft cards onto the components. It calls the existing `workspace_decide` and `workspace_send` events. It does not import Runner's backend, action schema, authentication, or delivery code.

The reused system includes the action-card shell, collapsed cards, expansion controls, email recipient fields, rich text editor, message editor, calendar review, inline fields, buttons, status badges, tooltips, dialogs, and their theme utilities. The remaining small UI primitives stay available for shared controls.

## Local adaptations

- Dialog and tooltip portals get a `runner-components` wrapper. Their CSS stays scoped beside Phoenix's existing Tailwind 3 stylesheet.
- The card height calculation supports a card that grows down the task page. The expand button opens the shared dialog. Controls expose expanded state and use Runner's touch target utility.
- Read-only card text remains selectable. Editable controls still disable during a request or disconnection.
- Email cards omit Runner file-handle attachments. Maraithon's current public draft contract does not expose them.
- Message destination types use the same small local shape, without importing Runner's backend client.
- Calendar review omits guest and calendar rows when the public card does not supply them. Its fields remain read-only, as required by Maraithon's current approval payload.
- The regular Markdown editor keeps Runner's nodes, table transformer, formatting shortcuts, and URL handling. Runner's file wiki-link editor is not imported.
- The switch does not call Runner's application sound service.

Runner's in-memory draft store stays intact. The Maraithon adapter restores and saves fields through the existing user/task storage key. Browser drafts stay in session storage. Electron drafts stay in its persistent origin profile. Chat messages still clear only after a server receipt.

## Build

Run `mix assets.setup` once after checkout. Run `mix assets.build` after changing components. Run `npm --prefix assets run typecheck` for the TypeScript compile check.

The component stylesheet compiles Runner's actual Tailwind 4 recipes and scopes them with PostCSS. Phoenix's existing page stylesheet continues to use Tailwind 3. Shared light, dark, type, icon, and mobile tokens come from `priv/static/styles/runner-theme.css`.

The Docker build installs the locked UI dependencies in a Node build stage. No dependency on the neighboring Runner checkout exists at build time or runtime.
