# Operator CLI

The repo now includes a first-party operator CLI implemented as Mix tasks. It talks to the same API surface the admin interface uses.

Configure it once:

```bash
export MARAITHON_BASE_URL="http://localhost:4000"
export MARAITHON_API_TOKEN="replace-with-your-api-token"
```

Agent lifecycle:

```bash
mix maraithon.agent list
mix maraithon.agent show AGENT_ID
mix maraithon.agent create --behavior prompt_agent --name inbox-watcher --prompt "Watch GitHub and Notaui." --subscriptions github:acme/repo,notaui:tasks --tools search_files,notaui_list_tasks
mix maraithon.agent update AGENT_ID --prompt "Updated prompt"
mix maraithon.agent start AGENT_ID
mix maraithon.agent stop AGENT_ID --reason maintenance
mix maraithon.agent delete AGENT_ID
mix maraithon.agent ask AGENT_ID "Summarize what needs attention."
mix maraithon.agent inspect AGENT_ID
mix maraithon.agent events AGENT_ID --limit 25
```

Fleet inspection:

```bash
mix maraithon.admin dashboard
mix maraithon.admin dashboard --activity-limit 20 --log-limit 100
```

The CLI is the terminal equivalent of the admin UI:

- `mix maraithon.admin dashboard` = fleet health, queue, failures, logs
- `mix maraithon.agent create|update|start|stop|delete` = agent CRUD and lifecycle
- `mix maraithon.agent inspect` = deep inspection for one agent
- `mix maraithon.agent ask` = operator console from the terminal

