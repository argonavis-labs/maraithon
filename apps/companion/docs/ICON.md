# App Icon

Maraithon ships a programmatically-generated app icon. The PNG bytes
are committed to the repo, but `scripts/generate_icon.swift` is the
source of truth — edit the script, re-run it, commit the diff.

## Regenerate

```sh
swift scripts/generate_icon.swift
```

This rewrites every PNG under
`Sources/Maraithon/Resources/Assets.xcassets/AppIcon.appiconset/` and
refreshes the Tahoe `docs/icon/AppIcon.icon.draft/` scaffold. The output is deterministic
— the same script run twice produces byte-identical PNGs.

## Design rationale

The glyph is a stylized capital "M" with a single sync arc above it.
The arc represents the local <-> cloud handshake: Maraithon's job is to
move iMessage data from the user's machine to the Maraithon server,
quietly and reliably. The M anchors the brand; the arc gives the icon
its meaning.

Constraints baked into the script:

- **Color.** Solid Apple system blue (`#007AFF`) on a solid white
  background. No gradient, no shadow, no rim lighting. This matches the
  weight of Mail / Calendar / Reminders rather than a marketing icon.
- **Stroke.** Sized as a fraction of the M's height (`0.20`), so the
  visual weight tracks the canvas at every output resolution.
- **Inset.** ~22% on each side. The macOS squircle is applied by the
  OS — the PNG is a full-bleed 1024 square — but the inset keeps the
  glyph clear of the rounded corners.
- **Reads at 16px.** The composition is two large shapes (M + arc)
  with a gutter between them, not fussy detail. It survives the
  16x16 menu-bar size.

## Output set

The asset catalog covers every standard macOS app-icon-set size:

| Logical | Scale | Pixels    |
|---------|-------|-----------|
| 16      | 1x    | 16x16     |
| 16      | 2x    | 32x32     |
| 32      | 1x    | 32x32     |
| 32      | 2x    | 64x64     |
| 128     | 1x    | 128x128   |
| 128     | 2x    | 256x256   |
| 256     | 1x    | 256x256   |
| 256     | 2x    | 512x512   |
| 512     | 1x    | 512x512   |
| 512     | 2x    | 1024x1024 |

Plus a 1024 master at `AppIcon.appiconset/icon_1024.png`.

Every size is rendered by re-running the same CoreGraphics drawing at
the target canvas size — there is no bitmap downscaling — so the
stroke stays sharp at small sizes.

## macOS 26 Tahoe migration

macOS 26 Tahoe ships a new icon format produced by Icon Composer.app,
documented at
[Updating application icons for macOS 26 Tahoe and Liquid Glass](https://successfulsoftware.net/2025/09/26/updating-application-icons-for-macos-26-tahoe-and-liquid-glass/).
The format is a `.icon` bundle containing a `manifest.json` plus
layered assets. The OS uses it to drive Liquid Glass effects (depth,
specular highlight, dynamic tint).

We ship a scaffold at
`docs/icon/AppIcon.icon.draft/` — a `manifest.json` plus the
1024 master PNG as a single layer. This is enough for the asset to be
recognized but does not yet take advantage of the new layering. When we
adopt Tahoe as a minimum deployment target, the migration plan is:

1. Open `docs/icon/AppIcon.icon.draft/icon_1024.png` in
   Icon Composer.app.
2. Split the M and the arc into separate layers; assign Liquid Glass
   material parameters per layer.
3. Export the resulting `.icon` bundle back to this path.
4. Bump `MACOSX_DEPLOYMENT_TARGET` and remove the asset-catalog
   fallback once everyone is on 26+.

Until then, the asset catalog is the primary delivery path.
