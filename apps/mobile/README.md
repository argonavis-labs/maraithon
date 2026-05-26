# Maraithon Mobile (iOS)

Native iOS app for mobile chief-of-staff workflows: Today, Todos, People, and
Chat.

## Build

From the monorepo root:

```sh
make generate
make build
make test
```

From this directory:

```sh
xcodegen generate
xcodebuild -project MaraithonMobile.xcodeproj \
  -scheme MaraithonMobile \
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  build
```

`project.yml` is the source of truth. The generated `.xcodeproj` is ignored.

## Production Simulator Verification

Copy the example config, fill local values, then run from the repo root:

```sh
cp Config/production-verification.env.example Config/production-verification.env
make verify-production-mobile
```

This gate signs into production, exercises todos, people, and chat, then
checks the API for the expected writes.
