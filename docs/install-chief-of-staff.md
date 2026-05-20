# Install Chief of Staff

Use this flow to install the Chief of Staff agent for a normal Maraithon account.

## Requirements

- A Maraithon account.
- One project on the dashboard.
- Telegram connected for delivery.
- Google connected with Gmail and Calendar access for briefing context.

## Steps

1. Sign in to Maraithon with your magic link.
2. Open **Connectors**.
3. Connect Telegram. Use the **Link Telegram** action, then finish the `/start` flow in Telegram. If the link is unavailable, message the bot with `/start your@email.com`.
4. Connect Google and grant Gmail plus Calendar access.
5. Open **Dashboard**.
6. Create a project if you do not already have one.
7. In **Install agent**, click **Install Chief of Staff**.
8. Open the installed agent to review status and adjust the morning brief time.

## Setup Required State

If you install before every required connector is ready, Maraithon records the agent as `setup_required` and keeps it stopped. It will not silently run without a delivery path or missing briefing sources. Connect the missing services, then use the dashboard install row again to enable the agent.

## First Brief

Enabled Chief of Staff agents use the existing morning schedule, defaulting to 8:00 AM at the configured timezone offset. The first due brief is picked up by the briefing scheduler once Telegram, Gmail, and Calendar are connected.
