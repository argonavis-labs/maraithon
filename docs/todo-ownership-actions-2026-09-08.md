# Todo ownership and action flow

Maraithon admits discovered work only when the source connects it to the user directly or implicitly. Authenticated Slack participant IDs and confirmed account identity are mandatory model context, even when optional context is trimmed. Channel membership and AI-generated relationship labels do not establish responsibility.

The existing ingestion model assesses personal involvement. Admission verifies the quoted source evidence and, for implicit work, the quoted connection to the user's responsibility. This stays on the existing model lane and durable task path. No new coordination process is introduced. A model outage queues discovery through the existing deferred ingestion lane; it never falls back to an unassessed direct upsert. Tool-submitted discoveries retain their provenance. CRM-enriched handles do not expand authenticated identity.

A version 6 todo brief supplies one concise summary and optional reply or phone action. It verifies ownership against source material; unavailable, unverified source material cannot generate an actionable commitment. Slack source retrieval and links use the saved workspace/channel/message reference. Canonical message links come from Slack's `chat.getPermalink` API.

Web, iPhone and Mac separate Summary from Details. Summary contains the source mark and actions; Details contains source history, supporting reasoning and metadata. Slack copies edited wording before opening the conversation. Email sends only on a user action; native clients confirm the reviewed message. Missing inputs prevent an acknowledgment from closing the task. Generated drafts are excluded from the evidence for the next brief; availability and promised deadlines must come from real evidence. Phone actions require a phone number present in source or contact evidence.

The paired-device API shares the existing mobile opened/reply endpoints, including tenancy from authentication, prepared-action idempotency and provider execution.

Validation: Phoenix compile, iPhone simulator build and SwiftPM Mac build. Automated tests remain unchanged and were not run under the manual-first development policy. Production and manual interaction results are recorded after deployment.

Production review on September 8 (UTC): the NewSmile item was dismissed using the domain API and Kent's ownership correction saved as an explicit instruction. Authenticated identity contains the three confirmed email addresses, with no CRM-expanded addresses. The live runtime recovered to 64 admitting partitions and no unproven assignments after the first two deployments.

The original NewSmile and Baselayer messages are absent from the synced event records, and Slack's live thread endpoint returned HTTP 429. Those older items therefore cannot supply a verified reply until source access recovers. New briefs use original synced Slack events where available and explicitly label partial coverage. Source history now projects Slack and local messages as well as email into Details.

Manual web review verified source logos, the Summary/Details switch, actual email history and a full 435-character clipboard copy. The first email preview exposed invented availability inherited from an older AI draft; version 6 removes that generated evidence and prevents a reply from resolving work with missing inputs. No email or Slack message was sent, and no phone call was placed. The native clients compiled successfully; these changes have not been distributed as a new native release.

The follow-up Slack search recovered both originals by channel name and exact timestamp. A bounded search fallback now checks both identifiers before using any result, carries Slack's canonical message URL, and labels the result as partial conversation coverage. The NewSmile source explicitly addresses another participant; the Baselayer source addresses the connected account. No generated reasoning is needed as a substitute for either message.

The post-deploy page check found a strict boolean guard applied to a URL string; the follow-up replaces it with an explicit type check. Runtime takeover reached 64 ready partitions and zero unproven tasks. The corrected page is reviewed again after this follow-up deployment.

Live revision 252 review: the email summary correctly leaves only the evening availability decision, removes invented dates, and avoids repeating Heather's already-supplied contact information. The Slack action copied an edited reply (verified through the browser clipboard) and opened the exact source-message URL. Browser sign-in to the Runner workspace is required in this in-app browser. No message was posted. Details exposed a missing `text` fallback in source-history projection; the final adapter correction includes Slack's text field.

Final release: revision `maraithon-00253-k2j`, image `dev-10b4a5d71499-20260908024903-1`. Live regeneration recovered Baselayer through the new search fallback, and Details displayed the exact original message, its September 4 timestamp, and the partial-history notice. This verifies the fallback and source-history projection together. The email brief records missing evening availability and `resolves_todo: false`. Both source examples remain open pending the user's scheduling decision. All implementation changes are synced into the original checkout, preserving the separate People work.
