#!/usr/bin/env bash
# Deploys seadata to a Venvy instance and publishes it at https://seadata.ringtwo.win.
#
#   VENVY_USER=admin VENVY_PASSWORD=… server/deploy/venvy.sh
#
# Optional: VENVY_URL (default https://venvy.ringtwo.win), VENVY_TOTP (6-digit code if 2FA is on), SEADATA_HOSTNAME (default seadata.ringtwo.win),
# SEADATA_PORT (default 8790), AISSTREAM_API_KEY (turns on AIS), OPEN_METEO_API_KEY (commercial plan),
# PUBLISH=0 to skip the Cloudflare tunnel (then it waits on HEALTH_URL, if given).
# Running it again uploads the new code and restarts the app. The Venvy host needs Rust
# (install Venvy with --with-rust); the first start compiles the server, which takes a few minutes.
set -euo pipefail

VENVY_URL="${VENVY_URL:-https://venvy.ringtwo.win}"
: "${VENVY_USER:?set VENVY_USER}"
: "${VENVY_PASSWORD:?set VENVY_PASSWORD}"
APP_NAME="${APP_NAME:-seadata}"
PUBLIC_HOST="${SEADATA_HOSTNAME:-seadata.ringtwo.win}"
APP_PORT="${SEADATA_PORT:-8790}"
VENVY_URL="${VENVY_URL%/}"

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
server="$(dirname "$here")"
repo="$(dirname "$server")"
jar="$(mktemp)"
trap 'rm -f "$jar"' EXIT
auth_key=""

say() { printf '\033[1m▸ %s\033[0m\n' "$*"; }
die() { printf '\033[31m✗ %s\033[0m\n' "$*" >&2; exit 1; }
py() { python3 -c "$1" "${@:2}"; }

# api METHOD PATH [curl args…]: prints the body, fails on HTTP errors with Venvy's message.
api() {
    local method="$1" path="$2"; shift 2
    local csrf; csrf="$(awk '$6 == "csrf_token" { print $7 }' "$jar" | tail -1)"
    local out status
    out="$(curl -sS -X "$method" -b "$jar" -c "$jar" \
        -H "X-Venvy-Key: $auth_key" -H "X-CSRF-Token: $csrf" \
        -w $'\n%{http_code}' "$VENVY_URL/api$path" "$@")"
    status="${out##*$'\n'}"
    out="${out%$'\n'*}"
    if [[ "$status" -ge 400 ]]; then
        die "$method $path → $status: $out"
    fi
    printf '%s' "$out"
}

wait_job() {
    local job="$1" status
    for _ in $(seq 1 300); do
        status="$(api GET "/jobs/$job" | py 'import json,sys; j=json.load(sys.stdin); print(j["status"], j.get("error") or "")')"
        case "$status" in
            done*) return 0 ;;
            error*) die "job $job failed: ${status#error }" ;;
        esac
        sleep 2
    done
    die "job $job did not finish"
}

say "Signing in to $VENVY_URL as $VENVY_USER"
api GET /auth/status >/dev/null
login="$(py 'import json,sys,os; d={"username":sys.argv[1],"password":sys.argv[2]}
if os.environ.get("VENVY_TOTP"): d["totp_code"]=os.environ["VENVY_TOTP"]
print(json.dumps(d))' "$VENVY_USER" "$VENVY_PASSWORD")"
auth_key="$(api POST /auth/login -H 'Content-Type: application/json' -d "$login" | py 'import json,sys; print(json.load(sys.stdin)["auth_key"])')"

app_id="$(api GET /apps | py 'import json,sys
apps=[a for a in json.load(sys.stdin) if a["name"]==sys.argv[1]]
print(apps[0]["id"] if apps else "")' "$APP_NAME")"

if [[ -z "$app_id" ]]; then
    say "Creating Rust app '$APP_NAME'"
    created="$(api POST /apps/upload -F "name=$APP_NAME" -F runtime=rust -F start_on_boot=true -F restart_policy=always)"
    app_id="$(py 'import json,sys; print(json.loads(sys.argv[1])["app_id"])' "$created")"
    wait_job "$(py 'import json,sys; print(json.loads(sys.argv[1])["job_id"])' "$created")"
fi
say "App id $app_id"

say "Uploading server code and chart packs"
files=(-F path=)
add() { files+=(-F "files=@$1;filename=$2"); }
add "$server/Cargo.toml" Cargo.toml
add "$server/Cargo.lock" Cargo.lock
add "$server/rustfmt.toml" rustfmt.toml
while IFS= read -r f; do add "$server/$f" "$f"; done < <(cd "$server" && find src -type f | sort)
for f in "$repo"/Leeway/Charts/*; do add "$f" "charts/$(basename "$f")"; done
skipped="$(api POST "/apps/$app_id/files/upload" "${files[@]}" | py 'import json,sys; print(json.load(sys.stdin)["skipped"] or "")')"
[[ -z "$skipped" ]] || die "Venvy skipped files: $skipped"

say "Configuring port $APP_PORT and environment"
settings="$(api GET /apps | py 'import json,sys,os
app=[a for a in json.load(sys.stdin) if a["id"]==int(sys.argv[1])][0]
env=json.loads(app.get("env_json") or "{}")
env.setdefault("CACHE_DIR", "cache")
env.setdefault("RUST_LOG", "seadata=info,tower_http=warn")
for key in ("AISSTREAM_API_KEY", "OPEN_METEO_API_KEY", "AIS_BBOX"):
    if os.environ.get(key): env[key]=os.environ[key]
port=int(sys.argv[2])
print(json.dumps({"port":port,"manual_ports":[port],"env_vars":env,"start_on_boot":True,"restart_policy":"always"}))' "$app_id" "$APP_PORT")"
api PUT "/apps/$app_id" -H 'Content-Type: application/json' -d "$settings" >/dev/null

status="$(api GET /apps | py 'import json,sys; print([a for a in json.load(sys.stdin) if a["id"]==int(sys.argv[1])][0]["status"])' "$app_id")"
action=start; [[ "$status" == running ]] && action=restart
say "Sending $action (was $status)"
sent=$(date +%s)
api POST "/apps/$app_id/control?action=$action" >/dev/null

health="${HEALTH_URL:-https://$PUBLIC_HOST/health}"
if [[ "${PUBLISH:-1}" == 0 ]]; then
    [[ -n "${HEALTH_URL:-}" ]] || { say "Started; not publishing (PUBLISH=0)"; exit 0; }
elif ! grep -q "\"$PUBLIC_HOST\"" <<<"$(api GET "/apps/$app_id/tunnel")"; then
    say "Publishing https://$PUBLIC_HOST through the Cloudflare tunnel"
    api POST "/apps/$app_id/tunnel/publish" -H 'Content-Type: application/json' \
        -d "{\"hostname\":\"$PUBLIC_HOST\",\"local_port\":$APP_PORT}" >/dev/null
fi

say "Waiting for $health (the first start compiles the server)"
down=0
for _ in $(seq 1 120); do
    # Only the new process counts: it must have started after the restart was sent.
    uptime="$(curl -fsS -m 5 "$health" 2>/dev/null | py 'import json,sys; print(json.load(sys.stdin).get("uptimeSeconds", 0))' 2>/dev/null || true)"
    if [[ -n "$uptime" ]] && (( uptime <= $(date +%s) - sent + 1 )); then
        say "Live: ${health%/health}/v1/info"
        curl -sS "${health%/health}/v1/info"; echo
        exit 0
    fi
    status="$(api GET /apps | py 'import json,sys; print([a for a in json.load(sys.stdin) if a["id"]==int(sys.argv[1])][0]["status"])' "$app_id")"
    # A restart passes through "stopped"; only give up once it stays down.
    if [[ "$status" == error || "$status" == stopped ]]; then down=$((down + 1)); else down=0; fi
    if [[ "$down" -ge 3 ]]; then
        api GET "/apps/$app_id/logs?lines=60" | py 'import json,sys; print(json.load(sys.stdin)["content"])'
        die "app is $status; log above"
    fi
    sleep 10
done
api GET "/apps/$app_id/logs?lines=40" | py 'import json,sys; print(json.load(sys.stdin)["content"])'
die "$health did not come up within 20 minutes; log above"
