#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONFIG_FILE="${MARAITHON_VERIFY_CONFIG:-${ROOT_DIR}/Config/production-verification.env}"
HELPER_FILE="${ROOT_DIR}/scripts/lib/production-magic-token.sh"

if [[ ! -f "${CONFIG_FILE}" ]]; then
  echo "Missing verification config: ${CONFIG_FILE}" >&2
  exit 1
fi

if [[ ! -f "${HELPER_FILE}" ]]; then
  echo "Missing production magic auth helper: ${HELPER_FILE}" >&2
  exit 1
fi

# shellcheck source=/dev/null
source "${CONFIG_FILE}"
# shellcheck source=/dev/null
source "${HELPER_FILE}"

: "${MARAITHON_FLY_APP:?MARAITHON_FLY_APP or FLY_APP is required in ${CONFIG_FILE}}"
: "${MARAITHON_VERIFY_EMAIL:?MARAITHON_VERIFY_EMAIL is required in ${CONFIG_FILE}}"
: "${MARAITHON_VERIFY_CONTACT_EMAIL_DOMAIN:?MARAITHON_VERIFY_CONTACT_EMAIL_DOMAIN is required in ${CONFIG_FILE}}"
: "${MARAITHON_PRODUCTION_BASE_URL:?MARAITHON_PRODUCTION_BASE_URL is required in ${CONFIG_FILE}}"
: "${MARAITHON_MOBILE_API_BASE_URL:?MARAITHON_MOBILE_API_BASE_URL is required in ${CONFIG_FILE}}"
: "${SIMULATOR_UDID:?SIMULATOR_UDID is required in ${CONFIG_FILE}}"

VERIFY_EMAIL="${MARAITHON_VERIFY_EMAIL}"
RUN_ID="${MARAITHON_VERIFY_RUN_ID:-$(date -u +%Y%m%d%H%M%S)}"
IOS_DESTINATION="${IOS_DESTINATION:-platform=iOS Simulator,id=${SIMULATOR_UDID}}"
MAX_UI_ATTEMPTS="${MARAITHON_VERIFY_UI_ATTEMPTS:-3}"
FAST_CHAT_MAX_SECONDS="${MARAITHON_FAST_CHAT_MAX_SECONDS:-5}"

require_command() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "Missing required command: $1" >&2
    exit 1
  }
}

require_command curl
require_command flyctl
require_command jq
require_command xcodebuild
require_command xcodegen

cd "${ROOT_DIR}"

echo "Verifying production mobile flow for ${VERIFY_EMAIL} (${RUN_ID})"
curl -fsS "${MARAITHON_PRODUCTION_BASE_URL}/health/" >/dev/null

xcodegen generate
xcrun simctl shutdown "${SIMULATOR_UDID}" >/dev/null 2>&1 || true
xcrun simctl boot "${SIMULATOR_UDID}" >/dev/null 2>&1 || true
xcrun simctl bootstatus "${SIMULATOR_UDID}" -b >/dev/null
xcodebuild \
  -quiet \
  -project MaraithonMobile.xcodeproj \
  -scheme MaraithonMobile \
  -destination "${IOS_DESTINATION}" \
  build-for-testing

run_ui_attempt() {
  local attempt_run_id="$1"
  local simulator_magic_code
  local config_path="/tmp/maraithon-production-verification.json"
  local status=0

  simulator_magic_code="$(generate_maraithon_magic_code "${MARAITHON_FLY_APP}" "${VERIFY_EMAIL}" "mobile-verification-loop")"

  jq -n \
    --arg magicCode "${simulator_magic_code}" \
    --arg runID "${attempt_run_id}" \
    --arg contactEmailDomain "${MARAITHON_VERIFY_CONTACT_EMAIL_DOMAIN}" \
    '{magicCode: $magicCode, runID: $runID, contactEmailDomain: $contactEmailDomain}' \
    >"${config_path}"

  env \
    MARAITHON_MAGIC_CODE="${simulator_magic_code}" \
    MARAITHON_VERIFY_RUN_ID="${attempt_run_id}" \
    MARAITHON_VERIFY_CONTACT_EMAIL_DOMAIN="${MARAITHON_VERIFY_CONTACT_EMAIL_DOMAIN}" \
    xcodebuild \
    -quiet \
    -project MaraithonMobile.xcodeproj \
    -scheme MaraithonMobile \
    -destination "${IOS_DESTINATION}" \
    -only-testing:MaraithonMobileUITests/ProductionIntegrationUITests/testProductionMagicSigninTodoAndPeoplePersistence \
    test-without-building || status=$?

  rm -f "${config_path}"
  return "${status}"
}

SUCCESS_RUN_ID=""
for attempt in $(seq 1 "${MAX_UI_ATTEMPTS}"); do
  ATTEMPT_RUN_ID="${RUN_ID}"
  if [[ "${attempt}" -gt 1 ]]; then
    ATTEMPT_RUN_ID="${RUN_ID}-retry${attempt}"
  fi

  echo "Production UI attempt ${attempt}/${MAX_UI_ATTEMPTS} (${ATTEMPT_RUN_ID})"
  if run_ui_attempt "${ATTEMPT_RUN_ID}"; then
    SUCCESS_RUN_ID="${ATTEMPT_RUN_ID}"
    break
  fi

  echo "Production UI attempt ${attempt} failed." >&2
done

if [[ -z "${SUCCESS_RUN_ID}" ]]; then
  echo "Production simulator verification failed after ${MAX_UI_ATTEMPTS} attempts." >&2
  exit 1
fi

RUN_ID="${SUCCESS_RUN_ID}"
TODO_TITLE="iOS prod work item ${RUN_ID}"
CONTACT_NAME="iOS Prod Person ${RUN_ID}"
UPDATED_CONTACT_NOTES="Updated from simulator ${RUN_ID}"
CHAT_PROBE_TEXT="Hey"
CHAT_TODO_TITLE="iOS chat assistant work item ${RUN_ID}"
FAST_CHAT_TEXT="Hey"
DEEP_CHAT_TEXT="Look up the contact named ${CONTACT_NAME} from my production contacts. What notes are stored for them? Include the exact stored notes string."

ASSERTION_MAGIC_CODE="$(generate_maraithon_magic_code "${MARAITHON_FLY_APP}" "${VERIFY_EMAIL}" "mobile-verification-loop")"
AUTH_JSON="$(curl -fsS -X POST "${MARAITHON_MOBILE_API_BASE_URL}/auth/magic-code" \
  -H 'Content-Type: application/json' \
  -H 'Accept: application/json' \
  -d "$(jq -n --arg code "${ASSERTION_MAGIC_CODE}" '{code: $code}')")"
SESSION_TOKEN="$(jq -r '.session_token' <<<"${AUTH_JSON}")"

if [[ -z "${SESSION_TOKEN}" || "${SESSION_TOKEN}" == "null" ]]; then
  echo "Unable to get assertion session token from production." >&2
  exit 1
fi

echo "Refreshing production local-pattern reminders for ${VERIFY_EMAIL}"
flyctl ssh console -a "${MARAITHON_FLY_APP}" \
  -C "env MARAITHON_VERIFY_EMAIL='${VERIFY_EMAIL}' bin/maraithon eval 'Application.load(:maraithon); Application.ensure_all_started(:ssl); Application.ensure_all_started(:cloak); Application.ensure_all_started(:cloak_ecto); {:ok, _vault} = Maraithon.Vault.start_link(); Application.ensure_all_started(:postgrex); Application.ensure_all_started(:ecto_sql); {:ok, _repo} = Maraithon.Repo.start_link(); email = System.fetch_env!(\"MARAITHON_VERIFY_EMAIL\"); IO.inspect(Maraithon.Proactive.LocalPatterns.run_for_user(email), label: \"local_patterns\")'" \
  >/dev/null

LOCAL_PATTERN_TODOS_JSON="$(curl -G -fsS "${MARAITHON_MOBILE_API_BASE_URL}/todos" \
  -H "Authorization: Bearer ${SESSION_TOKEN}" \
  --data-urlencode "source=local_patterns" \
  --data-urlencode "status=active" \
  --data-urlencode "limit=200")"

COLD_THREAD_TODO_COUNT="$(jq '[.todos[] | select((.metadata.detector // "") == "cold_thread")] | length' \
  <<<"${LOCAL_PATTERN_TODOS_JSON}")"

if (( COLD_THREAD_TODO_COUNT > 0 )); then
  jq -e '
    [.todos[] | select((.metadata.detector // "") == "cold_thread")] as $todos |
    all($todos[];
      (((.title // "") | test("^It.s been ")) | not) and
      (((.title // "") | test("\\+\\d{7,}")) | not) and
      (((.metadata.chat_display_name // "") | test("^\\+?[0-9 .()\\-]{7,}$")) | not) and
      ((((.summary // "") + " " + (.notes // "")) | contains("Why this matters:"))) and
      ((((.summary // "") + " " + (.notes // "")) | test("Last message from them:|Last thread:")))
    )
  ' <<<"${LOCAL_PATTERN_TODOS_JSON}" >/dev/null
else
  echo "No active production cold-thread todos found for ${VERIFY_EMAIL}; skipping copy assertion."
fi

TODO_JSON="$(curl -G -fsS "${MARAITHON_MOBILE_API_BASE_URL}/todos" \
  -H "Authorization: Bearer ${SESSION_TOKEN}" \
  --data-urlencode "q=${TODO_TITLE}" \
  --data-urlencode "status=all" \
  --data-urlencode "limit=20")"

PEOPLE_JSON="$(curl -G -fsS "${MARAITHON_MOBILE_API_BASE_URL}/people" \
  -H "Authorization: Bearer ${SESSION_TOKEN}" \
  --data-urlencode "q=${CONTACT_NAME}" \
  --data-urlencode "status=all" \
  --data-urlencode "limit=20")"

jq -e --arg title "${TODO_TITLE}" '.todos[] | select(.title == $title and .status == "done")' <<<"${TODO_JSON}" >/dev/null
jq -e --arg name "${CONTACT_NAME}" --arg notes "${UPDATED_CONTACT_NOTES}" \
  '.people[] | select(.display_name == $name and ((.notes // "") | contains($notes)))' \
  <<<"${PEOPLE_JSON}" >/dev/null

THREADS_JSON="$(curl -fsS "${MARAITHON_MOBILE_API_BASE_URL}/chat/threads?limit=20" \
  -H "Authorization: Bearer ${SESSION_TOKEN}")"

CHAT_THREAD_JSON=""
while IFS= read -r thread_id; do
  [[ -z "${thread_id}" ]] && continue
  CANDIDATE_JSON="$(curl -fsS "${MARAITHON_MOBILE_API_BASE_URL}/chat/threads/${thread_id}" \
    -H "Authorization: Bearer ${SESSION_TOKEN}")"

  if jq -e --arg prompt "${CHAT_PROBE_TEXT}" \
    '.thread.messages[] | select(.role == "user" and .body == $prompt)' \
    <<<"${CANDIDATE_JSON}" >/dev/null; then
    CHAT_THREAD_JSON="${CANDIDATE_JSON}"
    break
  fi
done < <(jq -r '.threads[].id' <<<"${THREADS_JSON}")

if [[ -z "${CHAT_THREAD_JSON}" ]]; then
  echo "Unable to find production mobile chat thread for verification prompt." >&2
  exit 1
fi

jq -e \
  '.thread.messages[] | select(.role == "assistant" and ((.run_id // "") != "") and (((.body // "") | startswith("Captured. Next best action")) | not))' \
  <<<"${CHAT_THREAD_JSON}" >/dev/null

FAST_CHAT_THREAD_ID="$(curl -fsS -X POST "${MARAITHON_MOBILE_API_BASE_URL}/chat/threads" \
  -H "Authorization: Bearer ${SESSION_TOKEN}" \
  -H 'Content-Type: application/json' \
  -H 'Accept: application/json' \
  -d "$(jq -n --arg client_thread_id "$(uuidgen | tr '[:upper:]' '[:lower:]')" \
    '{thread: {client_thread_id: $client_thread_id, title: "Mobile verification fast chat"}}')" |
  jq -r '.thread.id')"

FAST_CHAT_STARTED_SECONDS="$(date -u +%s)"
FAST_CHAT_JSON="$(curl -fsS -X POST "${MARAITHON_MOBILE_API_BASE_URL}/chat/threads/${FAST_CHAT_THREAD_ID}/messages" \
  -H "Authorization: Bearer ${SESSION_TOKEN}" \
  -H 'Content-Type: application/json' \
  -H 'Accept: application/json' \
  -d "$(jq -n --arg client_message_id "$(uuidgen | tr '[:upper:]' '[:lower:]')" \
    --arg body "${FAST_CHAT_TEXT}" \
    '{message: {client_message_id: $client_message_id, body: $body}}')")"
FAST_CHAT_ELAPSED_SECONDS="$(( $(date -u +%s) - FAST_CHAT_STARTED_SECONDS ))"

if (( FAST_CHAT_ELAPSED_SECONDS > FAST_CHAT_MAX_SECONDS )); then
  echo "Mobile fast chat took ${FAST_CHAT_ELAPSED_SECONDS}s, expected <= ${FAST_CHAT_MAX_SECONDS}s." >&2
  exit 1
fi

jq -e \
  '((.run.status // "completed") != "queued") and ((.run.status // "completed") != "running") and ((.thread.pending_run.status // "completed") != "queued") and ((.thread.pending_run.status // "completed") != "running")' \
  <<<"${FAST_CHAT_JSON}" >/dev/null

FAST_CHAT_THREAD_JSON="$(curl -fsS "${MARAITHON_MOBILE_API_BASE_URL}/chat/threads/${FAST_CHAT_THREAD_ID}" \
  -H "Authorization: Bearer ${SESSION_TOKEN}")"

jq -e '.thread.pending_run == null' <<<"${FAST_CHAT_THREAD_JSON}" >/dev/null

jq -e \
  '.thread.messages[] | select(.role == "assistant" and ((.run_id // "") != "") and ((.body // "") != "") and (((.body // "") | startswith("Captured. Next best action")) | not))' \
  <<<"${FAST_CHAT_THREAD_JSON}" >/dev/null

DEEP_CHAT_THREAD_ID="$(curl -fsS -X POST "${MARAITHON_MOBILE_API_BASE_URL}/chat/threads" \
  -H "Authorization: Bearer ${SESSION_TOKEN}" \
  -H 'Content-Type: application/json' \
  -H 'Accept: application/json' \
  -d "$(jq -n --arg client_thread_id "$(uuidgen | tr '[:upper:]' '[:lower:]')" \
    '{thread: {client_thread_id: $client_thread_id, title: "Mobile verification deep chat"}}')" |
  jq -r '.thread.id')"

DEEP_CHAT_SEND_JSON="$(curl -fsS -X POST "${MARAITHON_MOBILE_API_BASE_URL}/chat/threads/${DEEP_CHAT_THREAD_ID}/messages" \
  -H "Authorization: Bearer ${SESSION_TOKEN}" \
  -H 'Content-Type: application/json' \
  -H 'Accept: application/json' \
  -d "$(jq -n --arg client_message_id "$(uuidgen | tr '[:upper:]' '[:lower:]')" \
    --arg body "${DEEP_CHAT_TEXT}" \
    '{message: {client_message_id: $client_message_id, body: $body}}')")"

DEEP_CHAT_RUN_ID="$(jq -r '.run.id // .thread.pending_run.id // empty' <<<"${DEEP_CHAT_SEND_JSON}")"

if [[ -z "${DEEP_CHAT_RUN_ID}" ]]; then
  echo "Mobile deep chat did not create a production assistant run." >&2
  jq '.thread.messages' <<<"${DEEP_CHAT_SEND_JSON}" >&2
  exit 1
fi

DEEP_CHAT_RUN_STATUS=""
for _ in $(seq 1 150); do
  DEEP_CHAT_RUN_JSON="$(curl -fsS "${MARAITHON_MOBILE_API_BASE_URL}/chat/runs/${DEEP_CHAT_RUN_ID}" \
    -H "Authorization: Bearer ${SESSION_TOKEN}")"
  DEEP_CHAT_RUN_STATUS="$(jq -r '.run.status' <<<"${DEEP_CHAT_RUN_JSON}")"

  case "${DEEP_CHAT_RUN_STATUS}" in
    completed|degraded|failed|waiting_confirmation)
      break
      ;;
  esac

  sleep 2
done

if [[ "${DEEP_CHAT_RUN_STATUS}" != "completed" ]]; then
  echo "Mobile deep chat run did not complete successfully; last status: ${DEEP_CHAT_RUN_STATUS:-unknown}." >&2
  jq '.run' <<<"${DEEP_CHAT_RUN_JSON}" >&2
  exit 1
fi

DEEP_CHAT_THREAD_JSON="$(curl -fsS "${MARAITHON_MOBILE_API_BASE_URL}/chat/threads/${DEEP_CHAT_THREAD_ID}" \
  -H "Authorization: Bearer ${SESSION_TOKEN}")"

jq -e --arg note "${UPDATED_CONTACT_NOTES}" \
  '.thread.messages[] | select(.role == "assistant" and ((.run_id // "") != "") and (((.body // "") | contains($note))))' \
  <<<"${DEEP_CHAT_THREAD_JSON}" >/dev/null

API_CHAT_THREAD_ID="$(curl -fsS -X POST "${MARAITHON_MOBILE_API_BASE_URL}/chat/threads" \
  -H "Authorization: Bearer ${SESSION_TOKEN}" \
  -H 'Content-Type: application/json' \
  -H 'Accept: application/json' \
  -d "$(jq -n --arg client_thread_id "$(uuidgen | tr '[:upper:]' '[:lower:]')" \
    '{thread: {client_thread_id: $client_thread_id, title: "Mobile verification work item"}}')" |
  jq -r '.thread.id')"

SEND_CHAT_JSON="$(curl -fsS -X POST "${MARAITHON_MOBILE_API_BASE_URL}/chat/threads/${API_CHAT_THREAD_ID}/messages" \
  -H "Authorization: Bearer ${SESSION_TOKEN}" \
  -H 'Content-Type: application/json' \
  -H 'Accept: application/json' \
  -d "$(jq -n --arg client_message_id "$(uuidgen | tr '[:upper:]' '[:lower:]')" \
    --arg body "Create a new todo exactly titled ${CHAT_TODO_TITLE}. This is a production mobile verification." \
    '{message: {client_message_id: $client_message_id, body: $body}}')")"

CHAT_RUN_ID="$(jq -r '.run.id // .thread.pending_run.id // empty' <<<"${SEND_CHAT_JSON}")"

if [[ -n "${CHAT_RUN_ID}" ]]; then
  CHAT_RUN_STATUS=""

  for _ in $(seq 1 150); do
    CHAT_RUN_JSON="$(curl -fsS "${MARAITHON_MOBILE_API_BASE_URL}/chat/runs/${CHAT_RUN_ID}" \
      -H "Authorization: Bearer ${SESSION_TOKEN}")"
    CHAT_RUN_STATUS="$(jq -r '.run.status' <<<"${CHAT_RUN_JSON}")"

    case "${CHAT_RUN_STATUS}" in
      completed|degraded|failed|waiting_confirmation)
        break
        ;;
    esac

    sleep 2
  done

  if [[ "${CHAT_RUN_STATUS}" != "completed" && "${CHAT_RUN_STATUS}" != "degraded" && "${CHAT_RUN_STATUS}" != "waiting_confirmation" && "${CHAT_RUN_STATUS}" != "failed" ]]; then
    echo "Mobile chat todo run did not finish in time; last status: ${CHAT_RUN_STATUS:-unknown}." >&2
    exit 1
  fi

  if [[ "${CHAT_RUN_STATUS:-}" == "failed" ]]; then
    echo "Mobile chat todo run failed." >&2
    jq '.run' <<<"${CHAT_RUN_JSON}" >&2
    exit 1
  fi
fi

API_CHAT_THREAD_JSON="$(curl -fsS "${MARAITHON_MOBILE_API_BASE_URL}/chat/threads/${API_CHAT_THREAD_ID}" \
  -H "Authorization: Bearer ${SESSION_TOKEN}")"

PREPARED_ACTION_ID="$(jq -r '.thread.messages[].actions[]? | select(.decision == "confirm") | .id' \
  <<<"${API_CHAT_THREAD_JSON}" | head -n 1)"

if [[ -n "${PREPARED_ACTION_ID}" ]]; then
  curl -fsS -X POST "${MARAITHON_MOBILE_API_BASE_URL}/chat/prepared-actions/${PREPARED_ACTION_ID}/decision" \
    -H "Authorization: Bearer ${SESSION_TOKEN}" \
    -H 'Content-Type: application/json' \
    -H 'Accept: application/json' \
    -d "$(jq -n --arg client_message_id "$(uuidgen | tr '[:upper:]' '[:lower:]')" \
      '{decision: "confirm", client_message_id: $client_message_id}')" >/dev/null
fi

CHAT_TODO_JSON="$(curl -G -fsS "${MARAITHON_MOBILE_API_BASE_URL}/todos" \
  -H "Authorization: Bearer ${SESSION_TOKEN}" \
  --data-urlencode "q=${CHAT_TODO_TITLE}" \
  --data-urlencode "status=all" \
  --data-urlencode "limit=20")"

jq -e --arg title "${CHAT_TODO_TITLE}" '.todos[] | select(.title == $title)' <<<"${CHAT_TODO_JSON}" >/dev/null

echo "Production simulator verification passed for ${RUN_ID}"
echo "Work item: ${TODO_TITLE} (done)"
echo "Person: ${CONTACT_NAME} (notes updated)"
echo "Cold-thread todos: ${COLD_THREAD_TODO_COUNT} active rows verified for useful copy"
echo "Fast chat: ${FAST_CHAT_TEXT} replied in ${FAST_CHAT_ELAPSED_SECONDS}s without a pending run"
echo "Deep chat: production contact notes were recovered for ${CONTACT_NAME}"
echo "Chat: production assistant replied and created ${CHAT_TODO_TITLE}"
