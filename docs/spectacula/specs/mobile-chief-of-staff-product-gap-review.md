# Chief of Staff Product Operating System Specification

Status: Draft v3
Purpose: Define the product promise, user experience, judgment model, and quality bar for making Maraithon a world-class chief of staff that helps the user make better decisions faster with the right context.
Audience: Product reviewer, founder, chief-of-staff behavior designer, implementation lead.

## 1. Product Thesis

Maraithon should not be another task app, dashboard, inbox, or AI chat window. It should be the user's operating staff.

The job is to convert scattered signals into better decisions:

- What deserves attention?
- What can wait?
- What should be ignored?
- Who matters here?
- What context changes the decision?
- What can Maraithon prepare?
- What should the user approve?
- What should Maraithon remember so tomorrow is easier?

The strongest version of Maraithon is a decision-compression system. It reduces the time, attention, and emotional overhead required to move from "something happened somewhere" to "I know what to do."

The product should feel less like a reminder bot and more like a trusted chief of staff who is always nearby, understands the user's work and personal life, knows who matters, protects attention, prepares the next move, and learns from correction.

## 2. Research Inputs

This v3 spec incorporates outside product and organizational research to sharpen the "why" and "what."

| Source | Product implication for Maraithon |
| --- | --- |
| BCG, "Find the Right Chief of Staff and Help Them Excel" | A strong chief of staff reduces mental load, focuses priorities, amplifies reach, and acts as strategist/proxy. Maraithon should be judged on leverage, not notification volume. |
| McKinsey, "Seeing around corners: How to excel as a chief of staff" | The CoS role depends on trust, decision rights, strategic priority alignment, and anticipating what is coming. Maraithon must earn trust through source-backed context and careful judgment. |
| HBR, "The Case for a Chief of Staff" | The role sits across delegation, communication, cross-functional management, and leadership quality. Maraithon must connect work streams rather than simply list tasks. |
| Microsoft Work Trend Index 2025, "Breaking down the infinite workday" | Modern work is fragmented by overflowing email, messages, meetings, and interruptions. Maraithon must reduce interruption load, not add to it. |
| McKinsey decision-making research | Fast decisions and high-quality decisions are not opposites when decision type, ownership, and context are clear. Maraithon should classify decision type and provide the right amount of context. |
| McKinsey, "If we're so busy, why isn't anything getting done?" | Role clarity and decision rights improve decision speed; meetings should focus on decisions, not live information sharing. Maraithon should clarify "who decides, who acts, who waits." |
| Getting Things Done | Trusted systems work by capturing, clarifying, organizing, reflecting, and engaging. Maraithon should not stop at capture; it must clarify and help the user engage. |
| APA task-switching research | Switching tasks creates cognitive cost. Maraithon should protect focus and batch non-urgent work into review moments. |
| Apple Human Interface Guidelines | Mobile experiences should focus people on primary tasks and keep controls discoverable without clutter. Maraithon's mobile surface should be card-first, concise, and one-thumb usable. |

Reference URLs:

- https://www.bcg.com/publications/2024/how-ceos-find-a-chief-of-staff
- https://www.mckinsey.com/capabilities/strategy-and-corporate-finance/our-insights/seeing-around-corners-how-to-excel-as-a-chief-of-staff
- https://hbr.org/2020/05/the-case-for-a-chief-of-staff
- https://www.microsoft.com/en-us/worklab/work-trend-index/breaking-down-infinite-workday
- https://www.mckinsey.com/capabilities/people-and-organizational-performance/our-insights/good-decisions-dont-have-to-be-slow-ones
- https://www.mckinsey.com/capabilities/people-and-organizational-performance/our-insights/decision-making-in-the-age-of-urgency
- https://www.mckinsey.com/capabilities/people-and-organizational-performance/our-insights/if-were-all-so-busy-why-isnt-anything-getting-done
- https://gettingthingsdone.com/what-is-gtd/
- https://www.apa.org/research/action/multitask
- https://developer.apple.com/design/human-interface-guidelines/

## 3. The Product Job

The user hires Maraithon for leverage.

Leverage means the user can:

- preserve attention,
- make better decisions faster,
- keep relationships warm,
- avoid dropping commitments,
- stay present with family,
- enter meetings prepared,
- delegate cognitive cleanup,
- trust that important things become durable state,
- and stop reopening every app to remember what matters.

The product is failing when the user thinks:

- "Who is this person again?"
- "Why is this important?"
- "What exactly am I supposed to do?"
- "Didn't someone already reply?"
- "Why is this old low-priority thing nagging me?"
- "Can you just draft the response?"
- "Did you check my real sources or are you guessing?"
- "Why did you interrupt me for this?"

The product is working when the user thinks:

- "I know why this matters."
- "That is the right next step."
- "I can decide this in 10 seconds."
- "Maraithon caught something I would have missed."
- "Maraithon did not bother me with noise."
- "Tomorrow's briefing is better because of what I marked today."

## 4. Product Principles

### 4.1 Attention Is A Trust Account

Every proactive message spends trust. Every useful, timely, context-rich intervention earns trust.

Maraithon should interrupt only when the likely value exceeds the attention cost. Otherwise it should hold the item for review, digest, or meeting prep.

### 4.2 Context Before Action

No surfaced action is acceptable if the user lacks enough context to decide. Context is not decoration. It is the core product.

Every important card must answer:

- who,
- what,
- why now,
- what changed,
- what is already handled,
- what evidence exists,
- what Maraithon recommends,
- and what Maraithon can do next.

### 4.3 Judgment Beats Exhaustiveness

The user does not want everything. The user wants the right things, in the right order, at the right time.

Maraithon should be willing to hold, demote, batch, or ask "still important?" for stale or low-confidence work.

### 4.4 Family And Personal Life Come First

The system should treat family, health, travel, school, home logistics, and close personal obligations as first-class. Business work should not crowd out the user's real life by default.

### 4.5 Prepared Moves Beat Advice

The chief-of-staff product should not merely say "reply now." It should prepare the reply, suggest the owner/ETA/content, and ask for approval.

The leverage ladder is:

1. Notice.
2. Explain.
3. Recommend.
4. Prepare.
5. Execute after approval.
6. Learn.
7. Prevent recurrence.

Maraithon should climb as high on this ladder as safety and source confidence allow.

### 4.6 Be Humble About Sources

If Maraithon did not check a source, it should not imply that it did. If a connector is stale, missing, or unavailable, that must affect confidence and copy.

### 4.7 Natural Conversation, Not Magic Words

The user should be able to ask normal questions. The product should infer intent, ask short clarifying questions only when needed, and avoid keyword-triggered experiences that feel brittle.

### 4.8 Learning Must Be Visible

If the user says something is not important, wrong, stale, personal, family-critical, or noise, Maraithon should visibly learn and use that signal later.

## 5. The Chief Of Staff Roles Maraithon Must Play

| Role | What a human CoS would do | Maraithon product behavior |
| --- | --- | --- |
| Gatekeeper | Protect the principal's attention | Decide interrupt vs digest vs hold |
| Context builder | Prepare background before decisions | Attach person/project/source/thread context |
| Priority translator | Turn goals into today's focus | Rank by relationship, objective, time, family, and waiting state |
| Follow-through owner | Make sure commitments close | Create durable todos, review stale work, suggest next moves |
| Relationship steward | Maintain trust with people | Track who matters, what they need, and preferred tone/channel |
| Meeting strategist | Make meetings useful | Prep attendees, open loops, agenda, decision points, follow-ups |
| Delegator | Turn intent into prepared work | Draft replies, queue research, update CRM, create tasks |
| Truth teller | Say when something is low-confidence or no longer urgent | Surface source gaps, stale status, and uncertainty clearly |
| Memory keeper | Remember preferences and corrections | Write durable memory and improve future ranking/copy |
| Personal operator | Protect family and life logistics | Rank personal obligations above routine business noise |

## 6. Primary User Modes

Maraithon should adapt to the mode the user is in, because the same item has different value depending on time and context.

| Mode | User need | Product posture |
| --- | --- | --- |
| Morning start | Understand the day and choose first moves | Brief, then offer review actions |
| Between meetings | Decide one small thing quickly | Show only high-confidence, low-effort actions |
| Pre-meeting | Be prepared | Meeting prep card with relationship and open-loop context |
| Post-meeting | Close loops while fresh | Draft recap, create follow-ups, update CRM/memory |
| Weekend | Protect family/personal time | Personal logistics and next-week prep; routine business in digest |
| Travel | Avoid logistical misses | Calendar, confirmations, family, location-sensitive reminders |
| Deep work | Avoid interruption | Hold non-urgent items; allow explicit ask |
| Catch-up | See what changed | Delta digest, not full inbox replay |
| Relationship moment | Understand a person | "Who is this?", "What do I owe?", "When did we last talk?" |
| Delegation | Offload cognitive work | Receipt, queue, progress, result card |

## 7. Decision Types

Different decisions require different context. Maraithon should classify the decision before deciding how much context to present.

| Decision type | Examples | Product requirement |
| --- | --- | --- |
| Tiny reversible | Mark done, dismiss noise, snooze | Fast buttons, minimal friction |
| Prepared reply | Email/Slack/iMessage follow-up | Show person, thread state, draft, source evidence |
| Relationship judgment | Intro, apology, close collaborator, family contact | Include history, relationship strength, tone, consequences |
| Meeting decision | Attend, prep, agenda, follow-up | Include role, attendees, objective, open loops |
| Waiting-state decision | Who owes whom? | Clarify owner, latest actor, next expected move |
| Stale-item decision | Old follow-up ignored multiple times | Ask keep/dismiss; do not present as urgent |
| Strategic/project decision | Business objective, customer, investor, partner | More context, options, tradeoffs, possible delegation |
| Personal/family logistics | School, child, spouse, travel, household | Prioritize strongly and keep copy direct |
| Source-confidence decision | Missing iMessage/Notes/Gmail/Slack | Disclose gap and suggest setup only when useful |

## 8. The Decision Card

The Decision Card is the central product unit.

It is not a visual style. It is a promise: one item, one decision, enough context, clear next move.

### 8.1 Card Anatomy

| Part | Question it answers | Required quality |
| --- | --- | --- |
| Headline | What is this? | Specific, not generic |
| Decision | What do I need to decide? | One clear choice or next move |
| Person/context | Who is involved? | Name, company/project, relationship when known |
| Why now | Why am I seeing this now? | Time, waiting state, relationship, risk, or changed source |
| Thread/source state | Is this still open? | Latest actor, owner, completion signals, uncertainty |
| Recommendation | What would a good CoS do? | Opinionated but reversible when low confidence |
| Prepared move | What can Maraithon do? | Draft, queue, update, summarize, ask, prep |
| Evidence | Why should I trust this? | Short source-backed snippets and timestamps |
| Source health | What did you check? | Fresh/stale/missing sources |
| Actions | What can I tap? | Done, dismiss, important, snooze, draft, context, delegate |
| Learning | What happens if I correct this? | Clear memory/relevance effect |

### 8.2 Context Depth Rules

| Familiarity | Context needed |
| --- | --- |
| Close/frequent person | Short context; focus on current ask and suggested action |
| Known but infrequent person | Add relationship, last interaction, project, why they matter |
| Unknown person | Identify source, possible company/project, confidence, source gaps |
| Family/personal contact | Add family role, logistics impact, deadline, personal consequence |
| Business/project contact | Add company/project, objective, current waiting state, artifact/owner/ETA |
| Cold/noisy contact | Explain why surfaced and offer dismiss/see-less |

### 8.3 The 10/10 Card Rubric

A card scores 10/10 only if all are true:

1. The user can tell who or what it is in under 5 seconds.
2. The user can tell why it matters now.
3. The card distinguishes urgent from stale.
4. The card says what Maraithon checked.
5. The card says what it could not check.
6. The suggested next action is concrete.
7. A prepared move is offered when possible.
8. Actions are safe and reversible unless explicitly confirmed.
9. Copy sounds like a sharp human chief of staff, not a template.
10. User feedback changes future behavior.

## 9. Ranking And Attention Policy

### 9.1 Default Rank Order

1. Family/personal logistics with real-world consequences.
2. Close relationship where the user owes something.
3. Active business objective blocked on the user.
4. Important relationship-capital item such as intro, apology, investor, customer, partner.
5. Meeting prep or scheduling where timing matters.
6. Stale item needing keep-or-dismiss decision.
7. Low-confidence or cold work item.
8. Informational/no-action item.

### 9.2 What Gets To Interrupt

Interruptions should be rare and high-signal.

Allowed interruption classes:

- family/personal logistics that could cause real-world failure,
- meeting prep within a near time window,
- a close relationship actively waiting on the user,
- user is blocking an active business objective,
- security/account/payment/travel issue,
- newly changed context that invalidates a plan,
- user-marked important item,
- source failure that blocks a known high-priority workflow.

Everything else should go into digest, review queue, or passive visibility.

### 9.3 Stale Work Policy

If the user repeatedly ignores an item, Maraithon should infer that urgency may be wrong.

Stale copy should be:

```text
This has been sitting long enough that I would not treat it as urgent.
Do you still want to keep it active?
```

Actions:

- Keep active.
- Mark important.
- Dismiss.
- See less like this.

The product should not shame, nag, or imply negligence when the user has already declined to act.

## 10. Core Product Workflows

### 10.1 Morning Briefing

The morning briefing should be a situational read, not a task dump.

It should include:

- day shape,
- calendar constraints,
- family/personal logistics,
- top work obligations,
- relationship-sensitive items,
- stale items that need a keep/dismiss decision,
- source health,
- and a clear button to review actions.

It should not list every overdue item.

After the briefing:

1. User taps `Review actions`.
2. Maraithon presents one card at a time.
3. User acts or asks for more context.
4. Maraithon advances.
5. End summary explains what changed and what remains.

### 10.2 "What Should I Do Right Now?"

Maraithon should answer based on:

- time available,
- calendar next event,
- energy/context if known,
- family/personal priority,
- waiting states,
- actionability,
- and prepared moves available.

The answer should be 1-5 items maximum unless the user asks for more.

### 10.3 "Who Is This?"

This is one of the product's trust-defining flows.

The answer should include:

- likely identity,
- company/project,
- relationship to the user,
- why the person is showing up now,
- last interaction,
- open loops,
- source confidence,
- source gaps,
- suggested next step.

If confidence is low, Maraithon should say so and ask a short clarification.

### 10.4 "Prep Me For This Meeting"

Meeting prep should answer:

- What is this meeting?
- Why am I in it?
- Who is attending?
- What do I know about them?
- What are the open loops?
- What decision or outcome should I aim for?
- What should I ask?
- What should I avoid missing?
- What follow-up can Maraithon draft afterward?

Meeting prep should explicitly identify the user's role: decider, adviser, recommender, executor, observer, or unclear.

### 10.5 Reply And Follow-Up Debt

Reply debt is not "no sent reply found." It is a judgment about whether a human or objective is still waiting on the user.

Maraithon must distinguish:

- user owes reply,
- another person already covered it,
- thread is active,
- owner shifted,
- user owes artifact but not reply,
- stale and likely low priority,
- unclear.

The suggested action should be one of:

- approve draft,
- move to waiting,
- ask if still important,
- mark done,
- dismiss,
- ask for more context,
- queue research.

### 10.6 Personal And Family Logistics

Personal/family items should be treated with the same seriousness as business commitments and often ranked higher.

Examples:

- school events,
- sports practice,
- RSVP deadlines,
- household tasks,
- spouse/family requests,
- travel logistics,
- health/financial/admin deadlines.

The product should never bury these under routine work follow-ups.

### 10.7 Delegated Work

When the user asks something that requires more time:

1. Acknowledge quickly.
2. State what Maraithon will check.
3. Give a progress/receipt.
4. Return with a result card.
5. Offer prepared next actions.

The receipt matters because it preserves trust during latency.

## 11. Source Trust And Humility

The user should always know whether Maraithon is operating from full context, partial context, or guesswork.

### 11.1 Source Health In Product Copy

Use source health when it changes the answer.

Examples:

- "I checked Gmail, Calendar, CRM, and Slack."
- "I could not check iMessage because the Desktop App is not syncing messages."
- "This is low confidence because the person is not in CRM and I only found one email thread."
- "I found a later reply, so I would not treat this as urgent."

### 11.2 Desktop App Promotion

Promote the Desktop App only when it helps the current job.

Good:

```text
I can answer from Gmail and Calendar, but iMessage and Apple Notes would likely matter for this family logistics question. Connect the Desktop App if you want Maraithon to include texts and local notes securely.
```

Bad:

```text
Install the Desktop App to sync more data.
```

## 12. Mobile Product Requirements

Mobile is not a smaller desktop. It is the field surface.

The mobile product should be optimized for:

- one decision at a time,
- short windows between events,
- low typing,
- quick capture,
- meeting prep,
- source confidence,
- and resuming after interruption.

### 12.1 Mobile First Screen

The first screen should answer:

1. What is next?
2. What needs me?
3. What can I decide quickly?
4. What can Maraithon handle?

Recommended sections:

- Now.
- Next meeting.
- Top action.
- Personal/family item.
- Review queue.
- Capture.

### 12.2 Mobile Interaction Rules

- Cards over tables for action review.
- One primary action per card.
- Secondary actions are available but quiet.
- No dense explanatory text unless expanded.
- Easy resume after interruption.
- Same state as Telegram and web.

## 13. Web Product Requirements

Web is the control plane.

| Surface | Product job |
| --- | --- |
| Dashboard | Daily operating view, current queue, source health, next meeting |
| Todos | Dense searchable/filterable operational table |
| People | Relationship intelligence, context editing, merge/cleanup |
| Insights | Review suggestions, CRM cleanup, source gaps |
| Connectors | Trust and setup, not just OAuth status |
| Memory | What Maraithon has learned and how it affects behavior |
| Command palette | Fast navigation plus actions |

The web app should make it easy to audit why Maraithon thinks something matters.

## 14. Product Quality Bar

### 14.1 Good Chief Of Staff Copy

Good copy is:

- specific,
- calm,
- opinionated,
- source-aware,
- relationship-aware,
- honest about uncertainty,
- and action-oriented.

Bad copy is:

- generic,
- scolding,
- overconfident,
- repetitive,
- context-free,
- urgency-inflating,
- or a raw task dump.

### 14.2 Example

Weak:

```text
Reply to Michael Berlingo on "Starteryou UGC Campaigns".
Context: No later reply found. Due May 24.
Next: Reply now with owner, ETA, and artifact.
```

Strong:

```text
Michael Berlingo appears to be tied to the Starteryou UGC campaign thread in Gmail. This looks like a campaign-materials follow-up, not a generic inbox task.

Why now: the thread had a May 24 due marker and I did not find a later sent reply in the same Gmail thread.

Suggested next step: approve a short reply that says who owns the remaining materials, what is ready now, and when the next asset will land.
```

This is strong because it tells the user who, why, source state, project context, and the prepared move.

## 15. Learning Loop

Every user action should teach the system.

| User action | Product learning |
| --- | --- |
| Done | This was real and resolved |
| Dismiss | This was not worth action |
| Not important | Lower similar future items |
| Important | Raise similar future items |
| More context | Current card lacked enough context |
| Draft reply | Prepared actions are valuable for this class |
| Edit draft | Learn voice/context gap |
| Merge/update CRM | Improve future identity and relationship context |
| Source setup | Missing source was valuable |
| Stop/pause review | Review length or timing may be wrong |

The end-of-review summary should say what was learned when the learning is meaningful.

## 16. Product Scorecard

Maraithon should be scored against chief-of-staff outcomes.

| Dimension | 10/10 behavior |
| --- | --- |
| Attention judgment | Interrupts rarely and correctly |
| Context sufficiency | User does not need to ask "who is this?" after a card |
| Decision quality | Recommendations reflect relationship, time, and source state |
| Prepared leverage | Maraithon offers drafts/actions, not just reminders |
| Personal priority | Family/personal obligations are protected |
| Source honesty | Missing/stale data is clear |
| Learning | Corrections visibly improve future output |
| Mobile usefulness | User can decide while walking |
| Meeting readiness | User enters meetings with context and agenda |
| Relationship stewardship | Important relationships stay warm without generic nagging |

## 17. Product Risks

| Risk | Product consequence | Required guardrail |
| --- | --- | --- |
| Over-interruption | User stops trusting proactive messages | Interruption budget and digest defaults |
| Generic cards | User still has to do memory work | Strict context sufficiency gate |
| Overconfidence | Wrong actions or damaged trust | Source health and confidence language |
| Stale nagging | Product feels annoying | Stale keep/dismiss policy |
| Too much data | Privacy and cognitive overload | Evidence snippets, not dumps |
| No learning | Same mistakes repeat | Feedback-to-memory loop |
| Automation overreach | User feels unsafe | Approval-first prepared actions |
| Business over personal | Product fails real-life priorities | Family/personal rank boost |
| UI clutter | Mobile unusable | Card-first one-primary-action design |

## 18. What Must Be True Before Implementation Starts

The product direction is ready only when these are accepted:

- Maraithon is primarily a decision-compression system.
- Attention is protected by default.
- Every surfaced action needs enough context to decide.
- Action cards are the product unit.
- Review sessions are a primary workflow after briefings.
- Family/personal obligations outrank routine business.
- Prepared actions are central, approval-first.
- Source confidence must be visible.
- User correction must change future behavior.

## 19. Product Acceptance Tests

These are product-level tests, not unit tests.

| Scenario | Passing behavior |
| --- | --- |
| Weekend morning | Family/personal and next-week prep outrank routine stale work |
| Stale low-priority follow-up | Maraithon asks keep/dismiss, not urgent reply |
| Unknown person todo | Card identifies likely person/project or says unknown with source gaps |
| Reply debt thread already active | Copy says thread is moving, not "you owe reply" |
| User asks "what should I do now?" | Returns 1-5 ranked decisions with context |
| User asks "who is this?" | Reviews connected context and gives confidence |
| Meeting in 30 minutes | Prep card surfaces attendee context and objective |
| User dismisses pattern | Similar future items are demoted |
| User asks for draft | Prepared reply appears with source-grounded context |
| Missing iMessage/Notes | Desktop App is suggested only if relevant |

## 20. Open Product Questions

1. Should web search be automatic for unfamiliar business contacts, or only user-approved?
2. Should family/personal priority be configurable in v1, or part of the product's default stance?
3. How much should Maraithon explain ranking decisions to the user?
4. Should review sessions optimize for all open loops, top N, or time available?
5. Should the product expose a "what Maraithon learned" surface after every review or only when meaningful?
6. How assertive should Maraithon be when it thinks the user is ignoring something for good reason?
7. Where is the line between useful prepared action and overstepping?

## 21. Final Product Bar

Maraithon is 10/10 only when a user can open Telegram or mobile between meetings and feel:

```text
I know what matters.
I know why.
I know who is involved.
I know what to do.
Maraithon has already prepared the next move.
I can trust what it checked.
I can correct it, and it will learn.
```

Anything less is still a useful app, but not yet a great chief of staff.
