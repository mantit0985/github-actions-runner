#!/usr/bin/env bash
#
# Entrypoint for the self-hosted GitHub Actions runner container.
#
# Required environment variables (only on the first start, while no
# registration exists yet):
#   REPO_URL      Target repository or organization (https://github.com/owner[/repo])
#   RUNNER_TOKEN  Registration token from GitHub Actions settings
#
# Optional:
#   RUNNER_LABELS Comma-separated custom labels (default: "self-hosted")
#
set -Eeuo pipefail
RUNNER_MODE=${RUNNER_MODE:-persistent}
RUNNER_TOKEN_SOURCE=${RUNNER_TOKEN_SOURCE:-mint}

if [[ -r /etc/fleet-tier ]]; then
    TIER=$(head -1 /etc/fleet-tier | tr -d '[:space:]')
    if [[ -n "${TIER}" ]]; then
        RUNNER_LABELS="${RUNNER_LABELS:+${RUNNER_LABELS},}${TIER}"
    fi
fi
readonly RUNNER_HOME="/home/runner"
readonly CONFIG_ATTEMPTS=5

log() {
    printf '[entrypoint] %s\n' "$*" >&2
}
rate_log() {
    local event="$1"
    local ts
    ts=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
    log "[entrypoint] RATE ${ts} event=${event}"
}

fail() {
    log "ERROR: $*"
    rate_log "failed"
    exit 1
}

# ---------------------------------------------------------------------------
# Preflight
# ---------------------------------------------------------------------------
[[ -x "${RUNNER_HOME}/config.sh" ]] || fail "runner distribution incomplete: ${RUNNER_HOME}/config.sh missing or not executable"
[[ -x "${RUNNER_HOME}/bin/Runner.Listener" ]] || fail "runner distribution incomplete: ${RUNNER_HOME}/bin/Runner.Listener missing or not executable"

cd "${RUNNER_HOME}"

# ---------------------------------------------------------------------------
# Signal handling
#
# While this script runs, it is PID 1 and must forward SIGTERM/SIGINT to
# whatever child is active so a container stop is honored immediately.
# In epic mode the traps FORWARD and then RETURN: the main flow detects
# the listener exit and performs the deregistration (never inside the trap).
# Once the persistent runner is started via exec, the runner itself receives
# the signals directly and shuts down gracefully (it drains running jobs).
# ---------------------------------------------------------------------------
SHUTDOWN=""
forward_signal() {
    local sig="$1"
    if [[ -n "${child_pid:-}" ]] && kill -0 "${child_pid}" 2>/dev/null; then
        kill "-${sig}" "${child_pid}" 2>/dev/null || true
    fi
    SHUTDOWN=1
    if [[ "${RUNNER_MODE}" == "ephemeral" ]]; then
        rate_log "drain"
        return 0
    fi
    log "received SIG${sig}; shutting down"
    exit "$((128 + $(kill -l "${sig}")))"
}
trap 'forward_signal TERM' TERM
trap 'forward_signal INT' INT

child_pid=""

# ---------------------------------------------------------------------------
# Registration
#
# The registration state (.runner) lives in the container's writable layer or,
# with the reference deployment, in the runner-data volume, so it survives
# restarts and re-creation. Registration tokens expire one hour after being
# issued, so a token is only required on a volume's very first start.
# In epic mode a fresh token is obtained on EVERY start: either minted
# (RUNNER_TOKEN_SOURCE=mint, from the PAT file), minted from the installed
# repo-admin GitHub App (RUNNER_TOKEN_SOURCE=github-app, APP_ID env + App
# private key file), or consumed preminted (RUNNER_TOKEN_SOURCE=preminted,
# from the injected swarm secret file).
# Tokens and credentials are runtime-only: never env exports, never logs,
# never the volume or the image.
# ---------------------------------------------------------------------------
if [[ "${RUNNER_MODE}" == "ephemeral" ]]; then
    [[ -n "${REPO_URL:-}" ]] || fail "REPO_URL must be set (ephemeral mode)"
    case "${REPO_URL}" in
        https://*) ;;
        *) fail "REPO_URL must be an https:// URL, got: ${REPO_URL}" ;;
    esac

    if [[ "${RUNNER_TOKEN_SOURCE}" == "preminted" ]]; then
        RUNNER_TOKEN_FILE=${RUNNER_TOKEN_FILE:-/run/secrets/runner-token}
        if [[ ! -r "${RUNNER_TOKEN_FILE}" ]]; then
            fail "Preminted token file ${RUNNER_TOKEN_FILE} not readable"
        fi
        REG_TOKEN=$(<"${RUNNER_TOKEN_FILE}")
        if [[ -z "${REG_TOKEN}" ]]; then
            fail "Preminted token file ${RUNNER_TOKEN_FILE} is empty; inject a fresh preminted token"
        fi
    else
        repo_path=${REPO_URL#https://github.com/}
        if [[ "${repo_path}" == */* ]]; then
            api_path="repos/${repo_path}"
            owner=${repo_path%%/*}
        else
            api_path="orgs/${repo_path}"
            owner=${repo_path}
        fi
        if [[ "${RUNNER_TOKEN_SOURCE}" == "github-app" ]]; then
            if [[ -z "${APP_ID:-}" ]]; then
                fail "mint via App: APP_ID must be set for RUNNER_TOKEN_SOURCE=github-app"
            fi
            app_key_file="${APP_KEY_FILE:-/run/secrets/github-app-key}"
            if [[ ! -r "${app_key_file}" ]]; then
                fail "mint via App: GitHub App private key file ${app_key_file} not readable"
            fi
            # App JWT (RS256, iss=<APP_ID>, iat-30/exp+540) signed with node's
            # built-in crypto module; the key only ever exists as a file.
            app_jwt=$(node -e '
const crypto=require("crypto"),fs=require("fs");
const b64u=(s)=>Buffer.from(s).toString("base64url");
const now=Math.floor(Date.now()/1000);
const si=b64u(JSON.stringify({alg:"RS256",typ:"JWT"}))+"."+b64u(JSON.stringify({iss:Number(process.argv[2]),iat:now-30,exp:now+540}));
process.stdout.write(si+"."+crypto.sign("RSA-SHA256",si,fs.readFileSync(process.argv[1])).toString("base64url"));
' "${app_key_file}" "${APP_ID}")
            if [[ -z "${app_jwt}" ]]; then
                fail "mint via App: JWT sign failed"
            fi
            header_file="$(mktemp)"; chmod 600 "${header_file}"
            printf 'Authorization: Bearer %s\nAccept: application/vnd.github+json\nX-GitHub-Api-Version: 2022-11-28\n' \
                "${app_jwt}" > "${header_file}"
            if ! _resp=$(curl -sS -w '%{http_code}' -H @"${header_file}" \
                "https://api.github.com/app/installations"); then
                rm -f "${header_file}"
                fail "mint via App: installations request failed via curl"
            fi
            http_code="${_resp: -3}"
            body="${_resp:0:${#_resp}-3}"
            if [[ "${http_code}" -ne 200 ]]; then
                rm -f "${header_file}"
                fail "mint via App: installations request failed (status=${http_code})"
            fi
            app_installation_id=$(echo "${body}" | jq -r --arg owner "${owner}" \
                'if type == "array" then ([.[] | select(.account.login == $owner)][0].id // empty) else empty end' 2>/dev/null || true)
            if [[ -z "${app_installation_id}" ]]; then
                rm -f "${header_file}"
                fail "mint via App: no App installation found for ${owner}"
            fi
            if ! _resp=$(curl -sS -w '%{http_code}' -H @"${header_file}" -X POST \
                "https://api.github.com/app/installations/${app_installation_id}/access_tokens"); then
                rm -f "${header_file}"
                fail "mint via App: installation access token request failed via curl"
            fi
            http_code="${_resp: -3}"
            body="${_resp:0:${#_resp}-3}"
            if [[ "${http_code}" -ne 201 ]]; then
                rm -f "${header_file}"
                fail "mint via App: installation access token request failed (status=${http_code})"
            fi
            unset app_jwt
            app_install_token=$(echo "${body}" | jq -r .token)
            if [[ -z "${app_install_token}" ]]; then
                rm -f "${header_file}"
                fail "mint via App: failed to parse installation token from response"
            fi
            printf 'Authorization: Bearer %s\n' "${app_install_token}" > "${header_file}"
            if ! _resp=$(curl -sS -w '%{http_code}' -H @"${header_file}" -X POST \
                "https://api.github.com/${api_path}/actions/runners/registration-token"); then
                rm -f "${header_file}"
                fail "mint via App: registration token request failed via curl"
            fi
            rm -f "${header_file}"
            http_code="${_resp: -3}"
            body="${_resp:0:${#_resp}-3}"
            if [[ "${http_code}" -ne 201 ]]; then
                fail "mint via App: registration token request failed (status=${http_code})"
            fi
            REG_TOKEN=$(echo "${body}" | jq -r .token)
            if [[ -z "${REG_TOKEN}" ]]; then
                fail "mint via App: failed to parse registration token from response"
            fi
            unset app_install_token
        else
            PAT_FILE="${RUNNER_PAT_FILE:-/run/secrets/runner-pat}"
            if [[ ! -r "${PAT_FILE}" ]]; then
                fail "Runner PAT file ${PAT_FILE} not readable"
            fi
            PAT=$(<"${PAT_FILE}")
            api_url="https://api.github.com/${api_path}/actions/runners/registration-token"
            H="$(mktemp)"; chmod 600 "$H"
            printf 'Authorization: Bearer %s\n' "${PAT}" > "$H"
            if ! _resp=$(curl -sS -w '%{http_code}' -H @"$H" -X POST "${api_url}"); then
                rm -f "$H"
                fail "mint registration token: curl transport failed"
            fi
            rm -f "$H"
            http_code="${_resp: -3}"
            body="${_resp:0:${#_resp}-3}"
            if [[ "$http_code" -ne 200 ]]; then
                fail "mint registration token failed (status=$http_code)"
            fi
            REG_TOKEN=$(echo "${body}" | jq -r .token)
            if [[ -z "${REG_TOKEN}" ]]; then
                fail "failed to parse registration token from response"
            fi
            unset PAT
        fi
    fi
    unset PAT

    if [[ -n "${RUNNER_LABELS:-}" ]]; then
        labels="${RUNNER_LABELS}"
    else
        labels="self-hosted"
    fi

    log "registering runner with ${REPO_URL}"
    attempt=1
    while true; do
        "${RUNNER_HOME}/config.sh" \
            --url "${REPO_URL}" \
            --token "${REG_TOKEN}" \
            --labels "${labels}" \
            --unattended \
            --replace \
            --ephemeral \
            &
        child_pid=$!
        if wait "${child_pid}"; then
            child_pid=""
            log "registration succeeded"
            rate_log "register"
            break
        fi
        child_pid=""
        if [[ -n "${SHUTDOWN}" ]]; then
            log "shutdown during registration; deregistering best effort"
            "${RUNNER_HOME}/config.sh" remove --url "${REPO_URL}" --token "${REG_TOKEN}" || true
            unset REG_TOKEN
            rate_log "deregister"
            exit 0
        fi
        if (( attempt >= CONFIG_ATTEMPTS )); then
            fail "registration failed after ${CONFIG_ATTEMPTS} attempts. Check REPO_URL; if RUNNER_TOKEN_SOURCE=preminted the injected registration token may have expired (its validity is roughly one hour)."
        fi
        delay=$((5 * attempt))
        log "registration attempt ${attempt} failed; retrying in ${delay}s"
        sleep "${delay}" &
        child_pid=$!
        wait "${child_pid}" || true
        child_pid=""
        attempt=$((attempt + 1))
    done

    log "starting runner listener"
    "${RUNNER_HOME}/bin/Runner.Listener" run &
    child_pid=$!
    IDLE_EXIT_SECONDS=${IDLE_EXIT_SECONDS:-900}
    idle_seen=0
    start_ts=$(date +%s)
    while true; do
        if ! kill -0 "${child_pid}" 2>/dev/null; then
            wait "${child_pid}" || true
            break
        fi
        sleep 2
        if [[ ${idle_seen} -eq 0 ]] && pgrep -f "Runner.Worker" >/dev/null; then
            rate_log "job"
            idle_seen=1
        fi
        if [[ ${idle_seen} -eq 0 ]]; then
            now_ts=$(date +%s)
            elapsed=$((now_ts - start_ts))
            if (( elapsed >= IDLE_EXIT_SECONDS )); then
                kill "${child_pid}" 2>/dev/null || true
                rate_log "idle-exit"
                wait "${child_pid}" || true
                break
            fi
        elif ! kill -0 "${child_pid}" 2>/dev/null; then
            wait "${child_pid}" || true
            break
        fi
    done
    log "runner listener exited; deregistering"
    rate_log "deregister"
    "${RUNNER_HOME}/config.sh" remove --url "${REPO_URL}" --token "${REG_TOKEN}" || true
    unset REG_TOKEN
    exit 0
fi

if [[ -f "${RUNNER_HOME}/.runner" ]]; then
    log "existing registration found; skipping registration"
else
    [[ -n "${REPO_URL:-}" ]] || fail "REPO_URL must be set (no existing registration found)"
    [[ -n "${RUNNER_TOKEN:-}" ]] || fail "RUNNER_TOKEN must be set (no existing registration found)"
    case "${REPO_URL}" in
        https://*) ;;
        *) fail "REPO_URL must be an https:// URL, got: ${REPO_URL}" ;;
    esac

    if [[ -n "${RUNNER_LABELS:-}" ]]; then
        labels="${RUNNER_LABELS}"
    else
        labels="self-hosted"
    fi

    log "registering runner with ${REPO_URL}"
    attempt=1
    while true; do
        "${RUNNER_HOME}/config.sh" \
            --url "${REPO_URL}" \
            --token "${RUNNER_TOKEN}" \
            --labels "${labels}" \
            --unattended \
            --replace &
        child_pid=$!
        if wait "${child_pid}"; then
            child_pid=""
            log "registration succeeded"
            break
        fi
        child_pid=""
        if (( attempt >= CONFIG_ATTEMPTS )); then
            fail "registration failed after ${CONFIG_ATTEMPTS} attempts. Check REPO_URL, and note that registration tokens expire after one hour; generate a fresh one and restart the container."
        fi
        delay=$((5 * attempt))
        log "registration attempt ${attempt} failed; retrying in ${delay}s"
        # Backgrounded so an incoming SIGTERM/SIGINT interrupts the wait
        # immediately instead of waiting for the sleep to elapse.
        sleep "${delay}" &
        child_pid=$!
        wait "${child_pid}"
        child_pid=""
        attempt=$((attempt + 1))
    done
fi

# The registration token is no longer needed. Scrub it so it cannot leak into
# job environments once the runner starts.
unset RUNNER_TOKEN

# Start the runner listener in the foreground. exec replaces this shell, so
# the runner runs as PID 1 (with compose init: true, as the init's direct
# child) and receives SIGTERM/SIGINT itself.
log "starting runner listener"
exec "${RUNNER_HOME}/bin/Runner.Listener" run
