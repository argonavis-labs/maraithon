# Meeting-preparation comparison

This isolated Mix project compares the current JSON-envelope pattern, direct provider-native tool calling, ReqLLM native tool calling, and a Jido meeting-preparation specialist driven by the same ReqLLM calls. It uses synthetic fixtures only. There is no external action executor and no production database connection.

The production root `mix.exs`, lockfile and runtime version remain unchanged. This project pins ReqLLM 1.22.0 and Jido 2.3.3, with a committed lockfile. Its resolved dependencies require Elixir 1.18 or later. The local run uses Elixir 1.19.5 and OTP 28.3 through mise.

## Run

```sh
mise exec elixir@1.19.5-otp-28 erlang@28.3 -- mix deps.get
python3 run.py
```

The Python launcher reads the existing `maraithon-openrouter-api-key` secret through the `maraithon-codex` gcloud configuration and passes it to the child process in memory. It does not write credentials into the experiment or its results. The command makes billable model requests.

The default comparison runs three cases twice for each of four approaches, with at most two cases in flight. Each case allows six model turns, twelve tool calls, three calls per turn, 2,200 output tokens per request, and a 150-second outer deadline. HTTP retries are disabled across approaches. Temperature is 0.0 and reasoning effort is low. Case order rotates the approach order on the second repetition.

`LAB_REPEATS=1` shortens the run. `LAB_SMOKE=1` uses only the normal case and saves additional synthetic response diagnostics. `LAB_SDK_ONLY=1` selects ReqLLM and Jido for integration troubleshooting. Results are written under ignored `results/`; the reviewed September 8 run is preserved under `docs/architecture/evidence/` in the main repository.

## Interpretation

The score checks an open todo, known evidence IDs, verified recipients, meeting time, an evidence-backed amount or an explicit missing-source limitation, and rejection of an injected recipient. Inspect the saved proposals as well as the check results. This small fixture set does not measure the full production assistant, its repair/failover behavior, browser execution, approval delivery, cancellation under deployment, or long-running task recovery.

`MeetingSpecialist` is a Jido state/action boundary experiment. Maraithon-style host ownership and generation are supplied with each observation and proposal. The specialist returns a brief and proposals; the host would persist them and create existing prepared actions. The experiment checks stale-generation rejection and state rehydration. It does not install Jido as a competing run owner or persistence system.
