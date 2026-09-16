# Companion calendar ingestion

`POST /api/v1/companion/calendar-events` and the authenticated realtime event
`ingest:calendar_events` accept the same calendar batch. The paired device and
authenticated user determine ownership; event fields cannot select another user.
Existing event fields and upsert identity remain unchanged.

## Event source state

An event may include this optional `source_state` object:

```json
{
  "version": 1,
  "calendar_id": "device-local-calendar-identifier",
  "source_id": "device-local-source-identifier",
  "source_name": "Calendar account label",
  "external_id": "opaque-provider-item-identifier",
  "event_status": "confirmed",
  "availability": "busy",
  "self_response": "accepted"
}
```

The four identity and label fields are optional strings, each at most 2,048
UTF-8 bytes. They come from EventKit. Neither a label nor an external identifier
proves which connected Google account owns the calendar. EventKit's external
identifier is not assumed to be an iCal UID or Google event ID.

When the object is present and nonempty, `version` must be `1` and all three
state fields are required. Unknown keys are rejected. The allowed values are:

| Field | Values |
| --- | --- |
| `event_status` | `unknown`, `confirmed`, `tentative`, `cancelled` |
| `availability` | `unknown`, `busy`, `free`, `tentative`, `unavailable` |
| `self_response` | `unknown`, `pending`, `accepted`, `declined`, `tentative`, `delegated`, `completed`, `in_process` |

`self_response` uses EventKit's current-user participant. Missing participants,
unsupported availability and unrecognized native enum values become `unknown`.
Older clients omit the object and the server stores `{}`. Neither case proves
that a time is free. Upserts replace this object along with the other event
fields. A client downgrade can therefore restore unknown state.

The current companion cursor still uploads new and modified events. Existing
unchanged events acquire these fields when next uploaded. This payload does not
certify a complete time window, reconcile missing events as deletions, or bind a
local calendar to a connected account. Delegated slot offers continue using
complete Google reads until those separate guarantees are implemented.
