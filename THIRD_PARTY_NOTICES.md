# Third-party notices

The root MIT licence covers Maraithon's original code. It does not replace
the licences of dependencies, fonts, icons, or adapted UI material.

## Inter

The Inter variable fonts in `priv/static/fonts/inter` are copyright the Inter
Project Authors and use the SIL Open Font License 1.1. The full notice is
included in [the font directory](priv/static/fonts/inter/LICENSE.txt).

## Heroicons

The outline SVG paths used by web components come from
[Heroicons](https://github.com/tailwindlabs/heroicons), copyright Tailwind Labs,
under the MIT licence. See [the included licence](licenses/Heroicons-MIT.txt).

## Catalyst and Tailwind Plus

The web UI follows Catalyst and includes adaptations of its patterns in
`lib/maraithon_web/components`. The separately purchased UI kit is not bundled.
Applicable Tailwind Plus material retains the
[Tailwind Plus licence](licenses/Tailwind-Plus.md), including its restrictions
on redistributing components separately from an end product. That licence
permits an open-source end-user application such as Maraithon; it does not
grant a licence to extract and redistribute a UI kit or starter template.

Tailwind CSS itself is an open-source dependency with its own MIT licence.

## Provider logos

Connector and native-client assets include logos identifying services such as
Google Chrome, Gmail, Apple Messages, Slack, Notion, and Telegram. These brand
assets belong to their respective owners. The root MIT licence does not grant
trademark rights or relicense those assets. Preserve attribution and follow
each provider's brand guidelines when redistributing or changing them.

## Dependencies

Server dependency versions are recorded in `mix.lock`. Native dependencies
are declared in each app's `project.yml` and package manifests. Their upstream
licences continue to apply. Keep the relevant notices when distributing a
compiled release or bundling dependency source.
