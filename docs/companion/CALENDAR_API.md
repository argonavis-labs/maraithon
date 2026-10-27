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


## Complete availability window

`POST /api/v1/companion/calendar-availability` accepts a paired device's
`device_id` and `snapshot`. The server replaces that device's previous window
atomically. This endpoint does not alter calendar history or run discovery.

The version 1 snapshot requires `captured_at`, `from`, `until`, `calendars` and
`events`. Timestamps use UTC ISO 8601. Capture must be at most five minutes old
and the window at most 60 days. The entire payload is limited to 1 MiB, 64
calendars and 2,000 event occurrences. Partial or truncated windows must not be
sent. Calendar inventory includes calendars with no events. Each calendar has
`id`, `source_id`, `name` and `source_name`.

Each event has `guid`, `start_at`, `end_at`, `is_all_day` and the existing
version 1 `source_state`, with calendar and source IDs matching the inventory.
All-day occurrences also require floating `start_date` and exclusive `end_date`.
EventKit returns floating dates in the Mac's default timezone. The companion
preserves those dates and rounds an end time within a day up to the next day's
boundary; midnight remains exclusive. Calendar arithmetic handles daylight
saving changes. See Apple's [start-date contract](https://developer.apple.com/documentation/eventkit/ekevent/startdate).
Titles, notes, locations and attendees are excluded. Every occurrence must
overlap the declared window.

Successful writes return the normal ingestion counts. An identical retry
returns one duplicate without refreshing capture time; older or conflicting
captures are rejected. Revocation and token rotation are rechecked under the
device row lock. Calendar purges, revocation and re-pairing clear the snapshot.
The field is excluded from normal device queries and inspection output.

The Mac submits the upcoming 45 days plus the previous day on each existing
Calendar sync cycle, even when no event changed. Windows over the bounds are
not truncated and do not refresh availability. The history cursor is separate.

Settings → Assistant lets each user match their own connected Google accounts
to primary calendars on one paired Mac. The same choices are available on Web,
Mac and iPhone. The server validates account ownership, excludes dedicated
assistant accounts, and rejects duplicate or cross-device bindings. Existing
clients ignore the new top-level settings fields. No binding is inferred from
a calendar title or source label.

Slot proposals prefer this mirror only when all selected accounts are bound,
the whole required window is covered and capture is at most five minutes old.
A revoked device, missing calendar, pending calendar write or app write since
capture causes a complete Google fallback. The coverage receipt records the
source, capture time, bounds and bindings. Booking still makes fresh Google
reads immediately before creating the invitation. A recent local read is not
proof that CalDAV has already received every remote change.

Cancelled, free and declined occurrences do not block time; unknown availability
remains busy. All-day dates keep their floating calendar dates. Meeting counts
use the opaque EventKit external identifier and exact occurrence times to
recognize calendar copies. This identifier has a separate namespace from a
Google iCal UID. Missing identifiers remain distinct. Apple's
[identifier contract](https://developer.apple.com/documentation/eventkit/ekcalendaritem/calendaritemexternalidentifier)
documents duplicate copies and shared recurring identifiers.
