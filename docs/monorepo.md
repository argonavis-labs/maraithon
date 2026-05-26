# Maraithon Monorepo

This repository owns the full Maraithon stack:

- `.`: Phoenix web app, API, connectors, OTP runtime, and Fly deployment.
- `apps/companion`: native macOS companion app for local data sync.
- `apps/mobile`: native iOS app for on-the-go chief-of-staff workflows.

The Phoenix app intentionally remains at the repository root. That keeps the
current Fly release, `mix` aliases, Dockerfile, migrations, and production
runtime stable while the native clients live under `apps/`.

## Commands

Use the root `Makefile` for cross-stack work:

```sh
make generate                 # regenerate Xcode projects
make build                    # build web, companion, and mobile
make test                     # run web tests plus native local tests
make verify                   # full local verification loop
make verify-native            # native-only generation/build/test loop
make verify-production-mobile # production simulator flow, requires local config
make deploy                   # deploy the Phoenix/Fly production app
```

The verification scripts use language-native tooling:

- Phoenix: `mix precommit`
- macOS companion: `swift build`, `swift test`, and `xcodebuild`
- iOS mobile: `xcodegen` and `xcodebuild` against an available simulator

Set `IOS_DESTINATION='platform=iOS Simulator,id=<UDID>'` when you want a
specific simulator. Otherwise the scripts pick an available iPhone simulator.

## Generated Files

Both native apps use XcodeGen. `project.yml` is the source of truth and
`.xcodeproj` files are generated on demand, not committed. This avoids noisy
project-file conflicts and keeps source ownership clear.

## Local Config

Production mobile verification uses local, ignored config:

```sh
cp apps/mobile/Config/production-verification.env.example \
  apps/mobile/Config/production-verification.env
```

Fill in a local simulator UDID and verification account values before running
`make verify-production-mobile`.

## CI Shape

The default local loop is deterministic and does not depend on a fresh
production magic-link token. Production simulator verification is explicit
because it creates real API data and requires local operator credentials.
