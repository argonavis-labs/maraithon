"""Run the bounded synthetic comparison using the existing GSM credential."""
import os
import subprocess
from pathlib import Path

root = Path(__file__).resolve().parent
secret = subprocess.run([
    "gcloud", "--configuration=maraithon-codex", "secrets", "versions", "access", "latest",
    "--secret=maraithon-openrouter-api-key", "--project=maraithon",
], check=True, capture_output=True, text=True).stdout.strip()
env = dict(os.environ, MARAITHON_LAB_API_KEY=secret)
subprocess.run(["mise", "exec", "elixir@1.19.5-otp-28", "erlang@28.3", "--", "mix", "run", "run.exs"],
    cwd=root, env=env, check=True)
