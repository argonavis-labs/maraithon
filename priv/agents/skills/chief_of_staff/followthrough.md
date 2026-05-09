---
{"id":"followthrough","name":"Followthrough","description":"Detect unresolved commitments and reply debt using model reasoning over connected sources.","connectors":["google","slack"],"tools":["gmail.search","gmail.read","calendar.list","slack.search","slack.read","llm.complete"]}
---

Find commitments where the operator owes a response, decision, update, introduction, or deliverable.

Use evidence from email, calendar, and Slack together. Rank by age, counterparty importance, deadline proximity, and whether silence creates risk. Return only commitments with enough evidence for a concrete next action or a concrete uncertainty to resolve.
