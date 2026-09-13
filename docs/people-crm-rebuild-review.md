# People / CRM rebuild review

Date: 2026-09-07
Status: direction confirmed; all three client surfaces implemented and built.

## Confirmed answers

Kent confirmed iOS, web, and native desktop. The main experience is a 2D graph
explorer, with PageRank-like importance derived from Slack, email, SMS and
other connected communication. It must be its own subsystem and must not
slow the rest of the product. These answers supersede the earlier proposed default view.

The subsystem uses a dedicated queue with one worker, a separate one-connection
database pool, bounded source reads, and immutable indexed profile generations.
A fenced atomic pointer update publishes each complete generation. Clients
read the projection: source scans, LLM calls and PageRank do not run on People
requests or in ingestion transactions. A failed refresh leaves the previous
generation available with its actual freshness timestamp.

## Requested outcome

Rewrite People / CRM so the user understands who they are meeting and can
track the people they interact with most, through a network based on actual
communication. Kent requested a review and questions before rebuilding.

## Findings from the current code

| Finding | Evidence | Consequence for the rebuild |
| --- | --- | --- |
| The web page leads with family onboarding, duplicates, goals, and reconnect suggestions. Its person detail is primarily an editing form. | `lib/maraithon_web/live/people_live.ex`, `render/1` and `person_detail_panel/1` | Put meeting and communication context first; keep editing and cleanup accessible as secondary actions. |
| A communication score and personalized PageRank implementation already exist. The web list applies its own ranking after fetching 100 people; it does not render a network or use `network_rank` in that ranking. | `lib/maraithon/crm/communication_score.ex`, `lib/maraithon/crm/relationship_graph.ex`, `PeopleLive.refresh_people/1` and `relationship_rank/2` | Reuse sound identity and ingestion infrastructure, but replace the fragmented presentation and ranking contract. |
| Future calendar events enter historical communication scoring: the query has a lower date bound but no upper bound, and decay treats future dates as age zero. | `lib/maraithon/crm/interaction_events.ex`, `calendar_events/3` and `decay/2`; graph co-attendance has the same issue | Keep scheduled meetings separate from past activity. A meeting invite is also not proof of attendance. |
| A todo link is counted as an interaction and carries a higher base weight than email, messages, or calendar. | `InteractionEvents.todo_link_events/1`, `CommunicationScore.@source_weights` | Show open work as useful person context without making it evidence that a conversation happened. |
| Aggregated interaction events retain only person, time, source, and direction. Underlying observations retain item identity, participants, subject, and excerpt. | `interaction_events.ex`, `lib/maraithon/crm/observation.ex` | Preserve source references through aggregation so displayed activity can be explained and opened. |
| Meeting discovery drops attendees that do not resolve to an existing person and excludes events with more than ten attendees. | `lib/maraithon/crm/upcoming_meetings.ex` | A new person on the calendar must remain visible even when relationship history is unknown. Apply meeting relevance rules separately from communication weighting. |
| Graph edges represent shared calendar events, observation participants, or group-chat senders. Stored top connections expose a weight but no supporting source item. | `RelationshipGraph.person_edges/4` and `top_connections/3` | Label edges as observed shared context. Do not turn co-presence into a claim that two people know each other. Provide supporting evidence when inspecting an edge. |
| The two score refresh jobs are enqueued after relationship ingestion. Local message and calendar ingestion enqueue embeddings but do not directly enqueue these refreshes. | `lib/maraithon/runtime/background_job_handler.ex`, `lib/maraithon/local_messages.ex`, `lib/maraithon/local_calendar.ex` | Establish freshness from every included source and as time advances, rather than relying on another connector to trigger a refresh. Production freshness has not been verified. |
| The mobile People experience has Suggested, Goals, Open work, and All views with separate local priority rules. Its contact model still contains sales fields; graph fields serialized by the server are not decoded as person network context. | `apps/mobile/MaraithonMobile/Features/CRM/CRMView.swift`, `PeoplePriorityEngine.swift`, `Core/Models/CRMContact.swift`, `Core/API/MobileAPIClient.swift`, `lib/maraithon_web/controllers/mobile_json.ex` | If iPhone is included, rebuild its information model and presentation around the same server contract as web. |

## Accepted implementation

Kent confirmed iOS, web, native desktop, a 2D explorer as the primary experience,
and all connected communication sources. The subsystem must remain independent
of todo processing and source ingestion.

The implementation and its performance boundaries, API contract, verification,
and remaining source-data limitations are documented in [People network](people-network.md).
The findings above describe the original code reviewed before the rewrite.
The original web and iOS management screens now live in `PeopleManageLive` and
`CRMManageView`; new People surfaces use the shared server projection.

An earlier fictional design sketch remains under
`work/people-crm-preview/people-network.html` as review material only. It is not
an app surface or evidence of live-data verification.
