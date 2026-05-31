import Foundation

/// Source-specific assistant outcomes shown on healthy source panes.
extension SourceDetailCopy {
    static func capabilities(for sourceID: String, displayName: String) -> [SourceCapability] {
        switch sourceID {
        case "imessage":
            return [
                SourceCapability(
                    id: "people_threads",
                    title: "People and threads",
                    description: "Names the people, thread, and source behind a message when it matters.",
                    systemImage: "person.2"
                ),
                SourceCapability(
                    id: "reply_obligations",
                    title: "Reply obligations",
                    description: "Turns promised replies and unresolved asks into open work with source evidence.",
                    systemImage: "text.bubble"
                ),
                SourceCapability(
                    id: "reply_prep",
                    title: "Reply prep",
                    description: "Prepares replies from the conversation and keeps approval with you.",
                    systemImage: "square.and.pencil"
                )
            ]

        case "calendar":
            return [
                SourceCapability(
                    id: "meeting_prep",
                    title: "Meeting prep",
                    description: "Uses upcoming meetings, attendees, and timing when briefing your day.",
                    systemImage: "calendar.badge.clock"
                ),
                SourceCapability(
                    id: "personal_commitments",
                    title: "Personal commitments",
                    description: "Keeps family and personal calendar items visible when ranking the day.",
                    systemImage: "person.crop.circle.badge.checkmark"
                ),
                SourceCapability(
                    id: "schedule_followthrough",
                    title: "Schedule follow-through",
                    description: "Connects due work to the meetings and deadlines it affects.",
                    systemImage: "checkmark.seal"
                )
            ]

        case "notes":
            return [
                SourceCapability(
                    id: "decisions_context",
                    title: "Decisions and context",
                    description: "Brings project notes into answers about people, projects, and commitments.",
                    systemImage: "note.text"
                ),
                SourceCapability(
                    id: "prep_material",
                    title: "Prep material",
                    description: "Pulls relevant notes into meeting prep and follow-up reviews.",
                    systemImage: "doc.text.magnifyingglass"
                ),
                SourceCapability(
                    id: "background_detail",
                    title: "Background detail",
                    description: "Keeps useful written context available without making every note a task.",
                    systemImage: "text.magnifyingglass"
                )
            ]

        case "reminders":
            return [
                SourceCapability(
                    id: "personal_todos",
                    title: "Personal to-dos",
                    description: "Brings Mac reminders into the same priority view as open work.",
                    systemImage: "checklist"
                ),
                SourceCapability(
                    id: "due_dates",
                    title: "Due-date pressure",
                    description: "Uses reminder dates to surface commitments before they become late.",
                    systemImage: "calendar.badge.exclamationmark"
                ),
                SourceCapability(
                    id: "quiet_cleanup",
                    title: "Quiet cleanup",
                    description: "Reminders already in assistant context stay out of the way unless they change.",
                    systemImage: "tray.full"
                )
            ]

        case "voice_memos":
            return [
                SourceCapability(
                    id: "spoken_decisions",
                    title: "Spoken decisions",
                    description: "Makes locally transcribed memos available when you ask what you said or decided.",
                    systemImage: "waveform"
                ),
                SourceCapability(
                    id: "idea_recall",
                    title: "Idea recall",
                    description: "Connects useful voice notes to people, projects, and open work.",
                    systemImage: "lightbulb"
                ),
                SourceCapability(
                    id: "local_transcription",
                    title: "Local transcription",
                    description: "Transcribes audio on this Mac before sending searchable text.",
                    systemImage: "lock.doc"
                )
            ]

        case "files":
            return [
                SourceCapability(
                    id: "local_references",
                    title: "Local references",
                    description: "Makes recent documents and summaries available for recall.",
                    systemImage: "folder"
                ),
                SourceCapability(
                    id: "project_context",
                    title: "Project context",
                    description: "Connects files to the projects and commitments they support.",
                    systemImage: "doc.on.doc"
                ),
                SourceCapability(
                    id: "searchable_summaries",
                    title: "Searchable summaries",
                    description: "Uses compact summaries so long documents can still help answer questions.",
                    systemImage: "doc.text.magnifyingglass"
                )
            ]

        case "browser_history":
            return [
                SourceCapability(
                    id: "research_trail",
                    title: "Research trail",
                    description: "Recalls what you were looking at when a project or person comes up.",
                    systemImage: "safari"
                ),
                SourceCapability(
                    id: "source_backing",
                    title: "Source backing",
                    description: "Links answers to browsing evidence instead of relying on vague memory.",
                    systemImage: "link"
                ),
                SourceCapability(
                    id: "handoff_context",
                    title: "Handoff context",
                    description: "Helps resume work from the sites and docs you recently opened.",
                    systemImage: "arrowshape.turn.up.right"
                )
            ]

        default:
            return [
                SourceCapability(
                    id: "assistant_context",
                    title: "\(displayName) context",
                    description: "Adds this source to assistant answers, priority reviews, and open-work checks.",
                    systemImage: "sparkles"
                )
            ]
        }
    }

    static func privacyNotes(for sourceID: String, displayName: String) -> [SourceCapability] {
        switch sourceID {
        case "imessage":
            return [
                SourceCapability(
                    id: "local_filtering",
                    title: "Local filtering",
                    description: "Blocked phone numbers and emails are filtered on this Mac before anything leaves it.",
                    systemImage: "hand.raised"
                ),
                SourceCapability(
                    id: "encrypted_sync",
                    title: "Encrypted transfer",
                    description: "Message content is encrypted on this Mac before it is sent when encryption is enabled.",
                    systemImage: "lock.shield"
                ),
                SourceCapability(
                    id: "device_control",
                    title: "Device control",
                    description: "Revoke this Mac or delete Maraithon's copy of Messages data without changing Messages on this Mac.",
                    systemImage: "macbook.and.iphone"
                )
            ]

        default:
            return [
                SourceCapability(
                    id: "local_data_stays",
                    title: "Local data stays put",
                    description: "\(displayName) stays on this Mac; Maraithon only sends the records this source is allowed to read.",
                    systemImage: "externaldrive"
                ),
                SourceCapability(
                    id: "encrypted_sync",
                    title: "Encrypted transfer",
                    description: "Content is encrypted on this Mac before it is sent when encryption is enabled.",
                    systemImage: "lock.shield"
                ),
                SourceCapability(
                    id: "device_control",
                    title: "Device control",
                    description: "Revoke this Mac or delete Maraithon's copy of \(displayName) data without changing local files or apps.",
                    systemImage: "macbook.and.iphone"
                )
            ]
        }
    }
}
