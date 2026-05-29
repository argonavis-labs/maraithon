# People Onboarding For Family-Sensitive Todo Handling

Decision date: 2026-05-28

## Status

Proposed product guidance. This replaces the first draft that focused too much
on tuning individual todo classification. The product need is upstream: the
People section needs onboarding that lets the user explicitly teach Maraithon who
their family is, so family members are handled differently from work contacts.

## Context

The production reset surfaced todos like `Check in with Jack Fenwick`. The issue
is not just that this copy is vague. The issue is that Jack is Kent's son, and
Maraithon should know that before it decides what kind of insight, todo, memory,
or notification to create.

`GOALS.md` treats People/CRM as a core data model because most work is
relationship-shaped. It also says users should not have to manually declare
every relationship forever; the model should learn from sources. That remains
true, but family is a special enough domain that first-run setup should ask the
user directly. The system should not infer a child, spouse, parent, or sensitive
family role from thin evidence and then start producing generic follow-up todos.

The existing People surface already has useful building blocks:

- `/operator/people` is the CRM browser.
- `Maraithon.Crm.Person` stores relationship, preferred channel, cadence, notes,
  metadata, interaction counts, and contact details.
- `Maraithon.Crm.RelationshipPresets` already groups `Family & personal`
  presets including `Child`, `Spouse / partner`, `Parent`, `Sibling`, school /
  child-care, medical provider, and household service.
- The People detail panel lets the user edit relationship, cadence, channel, and
  context.

What is missing is an onboarding path that makes the family model explicit,
structured, and privacy-aware.

## Product Stance

Maraithon should treat family as a first-class relationship domain, not as a
variant of sales CRM.

Work contacts usually produce todos around replies, decisions, deliverables,
meetings, and waiting-on loops. Family members produce a different mix:

- concrete parent/household logistics;
- reminders the user explicitly asks for;
- school, child-care, medical, activity, and household proxy messages;
- low-pressure relationship rhythms the user may or may not want tracked;
- sensitive context that should be remembered carefully and surfaced quietly.

The People onboarding flow should let the user tell Maraithon those distinctions
once, then let Chief of Staff skills use that context when interpreting sources.

## External Best-Practice Inputs

This is product guidance, not parenting, medical, or legal advice.

- CDC guidance on connecting conversations says regular opportunities to talk
  with children and youth matter, and that open communication grows through
  patient, consistent, low-pressure opportunities. Product implication:
  relationship support should be opt-in and humane, not guilt-based.
  Source: https://www.cdc.gov/healthy-youth/connecting-conversations/index.html
- HealthyChildren.org / AAP guidance for communicating with teens emphasizes
  listening without overreacting. Product implication: family reminders should
  suggest open-ended human next steps, not managerial commands.
  Source: https://www.healthychildren.org/English/family-life/family-dynamics/communication-discipline/Pages/How-to-Communicate-with-a-Teenager.aspx
- Microsoft's notification guidance says effective notifications are useful,
  relevant, actionable, appropriately presented, and not annoying. Product
  implication: vague family nudges should not push; time-sensitive logistics can.
  Source: https://learn.microsoft.com/en-us/windows/win32/uxguide/mess-notif
- Calm Technology principles say technology should require the smallest possible
  amount of attention and respect social norms. Product implication: family
  context should usually live in quiet memory/digest unless it protects a real
  commitment.
  Source: https://principles.design/examples/principles-of-calm-technology
- NIST AI RMF guidance treats privacy-enhanced, transparent, explainable AI as
  core trust characteristics and notes that data minimization can support
  privacy-enhanced AI. Product implication: family setup should collect only the
  fields needed to improve decisions, and every family todo should be
  explainable from source plus People context.
  Source: https://airc.nist.gov/airmf-resources/airmf/3-sec-characteristics/
- FTC COPPA guidance is a reminder that children's personal information has
  special legal and privacy obligations in covered contexts. Product implication:
  do not expand child data collection, retention, or proactive delivery without
  deliberate privacy/legal review.
  Source: https://www.ftc.gov/business-guidance/resources/childrens-online-privacy-protection-rule-not-just-kids-sites

## Onboarding Entry Points

People onboarding should appear in three places:

1. **First People visit:** When the user opens `/operator/people` and has no
   family-domain people, show a compact setup band: `Tell Maraithon about your
   family so it can handle family messages differently from work.`

2. **Chief of Staff install / fresh-start flow:** Before or after connector
   health, ask for family context because it changes proactive behavior.

3. **Relationship insight review:** When Maraithon detects likely family
   relationships from sources, route the user to the same review flow instead of
   silently creating strong family assumptions.

This should be an onboarding flow inside the People product surface, not a
generic settings wizard.

## Onboarding Flow

### Step 1: Family Roster

Ask the user to add the small set of people Maraithon should treat as family.

Fields:

- Display name.
- Relationship preset: child, spouse/partner, parent, sibling, extended family,
  close friend, or custom.
- Optional contact hints: email, phone, Telegram, WhatsApp, iMessage handle.
- Optional note: `What should Maraithon remember about this person?`

Default stance:

- Do not ask for birthdates, school names, medical facts, or exact locations in
  first-run onboarding.
- If the person is a child/dependent, store only the minimum flag needed to
  change privacy and todo behavior.

Example entry:

```json
{
  "display_name": "Jack Fenwick",
  "relationship": "Child",
  "metadata": {
    "relationship_domain": "family",
    "relationship_preset": "child",
    "family_member": true,
    "family_role": "child",
    "dependent_context": true,
    "sensitivity": "child_family",
    "relationship_context_source": "people_onboarding"
  },
  "notes": "Jack is Kent's son. Frame items involving Jack as parent/family context, not generic contact follow-up."
}
```

### Step 2: Handling Preferences

For each family person or family group, ask how Maraithon should behave.

Suggested controls:

- Logistics only: create todos for deadlines, school forms, pickup/dropoff,
  travel, appointments, direct asks, and user-requested reminders.
- Quiet relationship support: include occasional family context in digest, but
  do not create standalone `check in` todos.
- Opt-in rhythm: allow a low-noise recurring reminder such as weekly planning or
  one-on-one time.
- Push policy: immediate Telegram only for time-sensitive logistics or explicit
  user-requested reminders; otherwise digest.

This is the missing distinction for Jack. The system should know whether Kent
wants family relationship rhythms tracked before it creates any `Check in with
Jack` todo.

### Step 3: Family Proxies

Let the user identify people and organizations that are family-related but not
family members:

- school / child-care contacts;
- teachers, coaches, activity organizers;
- pediatrician / medical office;
- household services;
- co-parenting or family logistics contacts.

Proxy fields:

- Display name / organization.
- Proxy type.
- Related family member, if known.
- Default handling policy.

Example:

```json
{
  "display_name": "Jack's school office",
  "relationship": "School or child-care contact",
  "metadata": {
    "relationship_domain": "family",
    "relationship_preset": "school_contact",
    "family_proxy": true,
    "proxy_for_person_id": "jack-person-id",
    "proxy_role": "school",
    "default_todo_policy": "family_logistics"
  }
}
```

### Step 4: Review Learned Suggestions

As connectors sync, Maraithon can suggest family relationships from sources, but
the UI should frame them as reviewable People setup:

- `Review relationship: Jack Fenwick as your child.`
- `Review link: this school contact may be related to Jack.`
- `This recurring family logistics sender should be handled as household, not
  work. Apply?`

These suggestions should require confirmation when they change family role,
child/dependent status, or proxy links. Confirmed direct-family suggestions
should write the same structured family metadata used by People setup so
privacy, delivery, and todo-policy rules apply immediately.

### Step 5: Privacy And Delivery Defaults

The setup should make privacy behavior explicit:

- Telegram proactive copy for `sensitivity: child_family` should be neutral by
  default.
- Sensitive details should remain in the source-backed detail view, not the
  push body.
- Family context should be auditable: every todo should answer "why did you
  think this was about Jack?" from People metadata plus source evidence.
- The user should be able to downgrade family relationship rhythms to digest or
  turn them off.

## Data Contract

Use existing CRM fields where possible and add structured metadata rather than a
new family table for v1.

Person fields:

| Field | Use |
|---|---|
| `relationship` | Human-readable relationship, e.g. `Child` |
| `communication_frequency` | User-stated cadence if meaningful |
| `preferred_communication_method` | Channel preference |
| `notes` | Human-readable context for assistant prompts |
| `metadata.relationship_domain` | `family`, `personal`, or `business` |
| `metadata.relationship_preset` | Existing preset id |
| `metadata.family_member` | Boolean for direct family |
| `metadata.family_role` | child, spouse_partner, parent, sibling, extended_family |
| `metadata.dependent_context` | Boolean for child/dependent handling |
| `metadata.sensitivity` | `child_family` or other privacy class |
| `metadata.relationship_context_source` | `people_onboarding`, `crm_insights`, `model_inferred`, etc. |
| `metadata.todo_policy` | `family_logistics_only`, `quiet_relationship_support`, `opt_in_rhythm` |
| `metadata.push_policy` | `urgent_logistics_only`, `digest_default`, `user_requested_only` |

Proxy metadata:

| Field | Use |
|---|---|
| `metadata.family_proxy` | Boolean |
| `metadata.proxy_for_person_id` | Related family member |
| `metadata.proxy_role` | school, teacher, coach, doctor, household_service |
| `metadata.default_todo_policy` | How source items should be interpreted |

Memory writes:

People onboarding should also write durable memory when a preference matters
outside the CRM row:

```json
{
  "kind": "preference",
  "title": "Family todo policy",
  "content": "For Jack Fenwick, create todos for concrete parent logistics, direct asks, explicit reminders, and deadlines. Do not create generic check-in todos unless Kent opts into a relationship rhythm.",
  "tags": ["family", "todo_policy", "people_onboarding"],
  "importance": 95,
  "confidence": 1.0
}
```

## Downstream Behavior

### Todo Intelligence

Todo intelligence should read People context before deciding family-related
candidates.

Acceptance rules:

- If `relationship_domain = family` and `todo_policy = family_logistics_only`,
  create todos only for logistics, deadlines, direct asks, explicit reminders,
  appointments, forms, travel, or source-backed parent action.
- If `todo_policy = quiet_relationship_support`, do not create standalone
  check-in todos. Store memory or include quiet digest observations.
- If `todo_policy = opt_in_rhythm`, create or maintain the requested rhythm with
  low-noise copy and digest-first delivery unless the user chose pushes.

### Follow-Through Insights

Follow-through should not treat family members as business counterparties. For
family people:

- `reply owed` language should be reserved for actual direct asks or user
  promises.
- `relationship drift` should not become debt copy.
- Proxies such as schools, teachers, or doctors can generate todos when there is
  a concrete action for Kent.

### Attention Ranking

Family should still rank high after a todo is accepted. The mistake is using
family importance as the reason to create a todo. Admission and ranking are
separate:

- admission: source-backed actionability plus People policy;
- ranking: family priority, deadline, relationship strength, and urgency.

### Telegram Delivery

For family-sensitive items:

- push immediately only for time-sensitive logistics, explicit user-requested
  reminders, or safety/health-sensitive deadlines;
- otherwise hold for digest or People detail review;
- keep push copy neutral and source-backed.

## UX Shape

Keep the People onboarding operational and row-oriented:

- A top setup band on `/operator/people`, not a marketing hero.
- A compact family roster table.
- Inline add/edit rows for family members and proxies.
- A right-side detail panel can reuse the current relationship form.
- Use existing relationship presets first; add metadata fields behind the
  scenes where possible.
- Provide `Skip for now` and `Remind me later`; do not block core use.

Suggested copy:

- Header: `Family context`
- Supporting text: `Tell Maraithon who is family so it can separate family
  logistics from work follow-ups.`
- Primary action: `Add family member`
- Secondary action: `Add school or household contact`

Do not use visible copy that says the assistant will monitor emotional state,
grade parenting, or optimize relationships.

## Eval Fixtures

Add fixtures before shipping implementation:

- `Jack is in People as child, logistics-only; no source ask` => no todo.
- `Jack is in People as child; school email asks Kent to sign a form by Friday`
  => family logistics todo.
- `Jack is in People as child; Kent explicitly says remind me Sunday to plan
  one-on-one time` => opt-in rhythm todo.
- `Jack is in People as child; model notices no recent contact` => no todo;
  optional digest only if quiet relationship support is enabled.
- `Teacher is linked as proxy for Jack; email includes pickup change today` =>
  urgent family logistics todo.
- `Work contact named Jack has business preset` => normal work follow-through,
  not family policy.

## Open Questions

- Should family onboarding live only in `/operator/people`, or should Telegram
  also offer a short conversational setup?
- Should child/dependent handling use a boolean only, or should the product
  eventually model age bands?
- Should `relationship_rhythm` become a first-class object rather than a todo
  policy in metadata?
- What exact retention and redaction rules should apply to child-family notes?

## Decision

Build a People-section onboarding path for family context before further tuning
family-related todo generation.

The specific product rule is:

> Family handling starts in People. The user should tell Maraithon who their
> family members and family proxies are, what kind of reminders they want, and
> how proactive the system should be. Chief of Staff todos and insights should
> then use that People context to distinguish family logistics from work
> follow-through and from generic relationship check-ins.
