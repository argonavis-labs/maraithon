# Maraithon Mobile — App Store Listing

Draft copy for the first App Store submission. Edit in place; the values are sized
to App Store Connect character limits.

---

## App Information

- **App name** (30 char): `Maraithon`
- **Subtitle** (30 char): `Your operational sidekick`
- **Bundle ID**: `com.bliss.maraithonmobile`
- **SKU**: `maraithon-mobile`
- **Primary category**: Productivity
- **Secondary category**: Business
- **Content rights**: Does not contain third-party content
- **Age rating**: 4+

## Promotional Text (170 char — can update without resubmit)

```
The mobile chief of staff for people who don't want a meeting just to remember
what they said yesterday. Today, todos, people, chat — one calm screen.
```

## Description (4000 char)

```
Maraithon is the mobile companion to your always-on AI chief of staff. It keeps
your day, your todos, your people, and your background work in one calm, fast,
operational app — built for busy humans, not for marketing screenshots.

What you get:

• Today — A single screen for what actually needs your attention right now.
  Calendar, open loops, drafts waiting on you, and the next concrete move.

• Todos — Quick capture, fast triage, and a real waiting-on list. The stuff
  you owe people, and the stuff people owe you, in one place.

• People — A lightweight CRM that remembers what matters about the humans in
  your week. Last contact, open threads, what you promised them.

• Chat — Direct line to your Maraithon agent. Ask, delegate, redirect, and
  see what it's working on in the background.

Maraithon is built around a different premise than most AI apps. Instead of a
chatbot you have to prompt, it's a long-lived agent that watches your inbox,
your calendar, your tools, and surfaces only what needs you. The mobile app is
the operational surface for that work: scan, decide, move on.

Designed for people who run companies, manage teams, and don't have time for
another app that demands attention. Calm, scannable, row-oriented. No
gradient heroes. No cards-within-cards. Just your day.

Requires a Maraithon account. Sign in with your email and we'll send a magic
link.
```

## Keywords (100 char, comma-separated, no spaces after commas)

```
chief of staff,productivity,todo,crm,assistant,agent,operations,inbox,founder,executive
```

## What's New in This Version (4000 char)

```
First release. Today, Todos, People, and Chat — the mobile surface for your
Maraithon agent. Sign in with email magic link.
```

## URLs

- **Support URL**: `https://maraithon.com/support` _(confirm)_
- **Marketing URL**: `https://maraithon.com` _(confirm)_
- **Privacy Policy URL**: `https://maraithon.com/privacy` _(REQUIRED — must exist before submission)_

## Privacy / Data Collection (App Store Connect → App Privacy)

Maraithon collects these data types and links them to identity:

- Contact Info: Email address (for sign-in)
- Identifiers: User ID (account)
- Usage Data: Product interaction (analytics)
- Diagnostics: Crash data, performance data

Not collected:
- Location
- Health & Fitness
- Financial Info
- Sensitive Info
- Browsing History
- Search History
- Contacts
- User Content (note: agent context lives in your Maraithon account, not on
  device — declare server-side handling in your privacy policy)

Tracking: No third-party tracking SDKs (confirm before submission).

## Test Information for App Review (TestFlight + App Review)

```
Sign in flow:
1. Tap "Sign in" on the welcome screen.
2. Enter the demo account email: reviewer@maraithon.com
3. We will provide a one-time magic link or a fixed dev code below.

Demo magic code: <ADD BEFORE SUBMISSION>

App requires a Maraithon account because the entire product is a personal
operational surface. Reviewer-only credentials are seeded with sample todos,
people, and chat threads.

Contact: kent@runner.now
```

## Required Screenshots

App Store Connect requires the largest iPhone size; older sizes are auto-derived.

### iPhone 6.9" (REQUIRED) — 1320 x 2868 portrait
Target device: iPhone 17 Pro Max / iPhone 16 Pro Max simulator.

Capture these 5 frames in order:

1. **Today** — main "Today" screen with a few open loops
2. **Todos** — todo list with a couple of waiting-on items
3. **People** — CRM list with 4–5 contacts, one with a recent thread
4. **Chat** — chat thread with the agent (one user message, one agent reply)
5. **Sign in / welcome** — clean shot of the sign-in screen (optional, can replace)

### iPad 13" (optional, only if iPad listing is offered)
Skip for v1 unless we're committing to iPad polish.

## Submission Checklist

- [ ] Bundle ID registered in Apple Developer portal
- [ ] App record created in App Store Connect
- [ ] Apple ID signed in to Xcode (Xcode → Settings → Accounts)
- [ ] Distribution cert + App Store provisioning profile created (auto-signing handles)
- [ ] ITSAppUsesNonExemptEncryption=false in Info.plist (done)
- [ ] Privacy policy URL live at marketing site
- [ ] Support URL live at marketing site
- [ ] App icon 1024x1024 included (done)
- [ ] Screenshots captured for 6.9" iPhone
- [ ] Listing copy finalized
- [ ] App privacy answered in App Store Connect
- [ ] Demo account seeded with reviewer-friendly data
- [ ] Build uploaded via `make ship-mobile`
- [ ] Build assigned to TestFlight internal testers
- [ ] Dogfood internally for 24–48h
- [ ] Submit for App Store review
