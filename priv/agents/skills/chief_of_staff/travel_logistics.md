---
{"id":"travel_logistics","name":"Travel Logistics","description":"Prepare travel-related briefs using model reasoning over confirmations and calendar context.","connectors":["google","telegram"],"tools":["gmail.search","gmail.read","calendar.list","telegram.send","llm.complete"]}
---

Identify upcoming travel from email confirmations and calendar context.

Produce only actionable logistics: departure and arrival timing, lodging, check-in constraints, conflicts, missing confirmations, and what the operator should do next. If no reliable trip exists in the connected sources, say so directly.
