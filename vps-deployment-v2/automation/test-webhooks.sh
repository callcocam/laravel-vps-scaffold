#!/usr/bin/env bash
# test-webhooks.sh — Dry-run webhook test for Discord/Slack alert validation
# Usage: ./test-webhooks.sh [--manifest /path/to/manifest.env] [--dry-run]
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MANIFEST="${MANIFEST:-}"
DRY_RUN=false

# ─── Parse arguments ─────────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
    case "$1" in
        --manifest)
            MANIFEST="$2"
            shift 2
            ;;
        --dry-run)
            DRY_RUN=true
            shift
            ;;
        *)
            echo "Unknown argument: $1" >&2
            echo "Usage: $0 [--manifest /path/to/manifest.env] [--dry-run]" >&2
            exit 1
            ;;
    esac
done

# ─── Load manifest ────────────────────────────────────────────────────────────
if [[ -z "$MANIFEST" ]]; then
    MANIFEST="${SCRIPT_DIR}/../templates/manifest.example.env"
fi

if [[ -f "$MANIFEST" ]]; then
    # shellcheck disable=SC1090
    set -a; source "$MANIFEST"; set +a
fi

# ─── Colours ─────────────────────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
RESET='\033[0m'

log_info()    { echo -e "${CYAN}[INFO]${RESET}  $*"; }
log_ok()      { echo -e "${GREEN}[OK]${RESET}    $*"; }
log_warn()    { echo -e "${YELLOW}[WARN]${RESET}  $*"; }
log_fail()    { echo -e "${RED}[FAIL]${RESET}  $*"; }
log_header()  { echo -e "\n${BOLD}${CYAN}=== $* ===${RESET}"; }

# ─── Webhook map ─────────────────────────────────────────────────────────────
# Keys: friendly names. Values: env variable names holding the URL.
declare -A WEBHOOK_MAP=(
    ["backup-failure"]="BACKUP_ALERT_WEBHOOK_URL"
)

# Order for display
WEBHOOK_ORDER=("backup-failure")

# ─── Build payload ────────────────────────────────────────────────────────────
build_payload() {
    local name="$1"
    local severity="$2"
    local timestamp
    timestamp="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
    local project="${PROJECT_NAME:-myapp}"
    local host="${APP_HOST:-vps}"

    # Try Discord payload first (has 'embeds'), fallback Slack-compatible JSON.
    # Both Discord and Slack accept a JSON body; we send a payload that works
    # with both by including a top-level "text" field (Slack) and "embeds" (Discord).
    cat <<JSON
{
  "username": "Plannerate Alerts",
  "text": "[TEST] ${severity^^} alert from ${project}@${host}",
  "embeds": [
    {
      "title": ":white_check_mark: Webhook test — ${name}",
      "description": "This is a **dry-run test** sent by \`test-webhooks.sh\` to validate the **${name}** webhook channel.",
      "color": $(webhook_color "$severity"),
      "fields": [
        { "name": "Project",    "value": "${project}", "inline": true },
        { "name": "Host",       "value": "${host}",    "inline": true },
        { "name": "Severity",   "value": "${severity^^}", "inline": true },
        { "name": "Timestamp",  "value": "${timestamp}", "inline": false }
      ],
      "footer": { "text": "vps-deployment-v2 / test-webhooks.sh" }
    }
  ],
  "attachments": [
    {
      "fallback": "[TEST] ${severity^^} alert — ${name} webhook is reachable",
      "color": "$(slack_color "$severity")",
      "title": ":white_check_mark: Webhook test — ${name}",
      "text": "Dry-run from \`${project}@${host}\`. The *${name}* webhook is reachable.",
      "fields": [
        { "title": "Severity", "value": "${severity^^}", "short": true },
        { "title": "Time",     "value": "${timestamp}", "short": true }
      ],
      "footer": "vps-deployment-v2"
    }
  ]
}
JSON
}

webhook_color() {
    case "$1" in
        critical)     echo "15158332" ;;  # red
        warning)      echo "16776960" ;;  # yellow
        backup*)      echo "16744272" ;;  # orange
        *)            echo "3066993"  ;;  # green
    esac
}

slack_color() {
    case "$1" in
        critical)     echo "danger"  ;;
        warning)      echo "warning" ;;
        backup*)      echo "#FF8C00" ;;
        *)            echo "good"    ;;
    esac
}

# ─── Send webhook ─────────────────────────────────────────────────────────────
send_webhook() {
    local name="$1"
    local url="$2"
    local severity="$3"

    local payload
    payload="$(build_payload "$name" "$severity")"

    if [[ "$DRY_RUN" == "true" ]]; then
        log_warn "DRY-RUN — would execute:"
        echo "  curl -s -o /dev/null -w '%{http_code}' \\"
        echo "    -H 'Content-Type: application/json' \\"
        echo "    -d '<payload>' \\"
        echo "    '${url}'"
        return 0
    fi

    local http_code
    http_code=$(curl -s -o /tmp/webhook_response.tmp -w '%{http_code}' \
        --max-time 10 \
        -H "Content-Type: application/json" \
        -d "$payload" \
        "$url" 2>/dev/null) || true

    if [[ "$http_code" =~ ^2 ]]; then
        log_ok "${name} → HTTP ${http_code}"
    else
        local body
        body=$(cat /tmp/webhook_response.tmp 2>/dev/null || echo "(no response body)")
        log_fail "${name} → HTTP ${http_code} — ${body:0:120}"
        return 1
    fi
}

# ─── Main ─────────────────────────────────────────────────────────────────────
main() {
    log_header "Webhook Test — vps-deployment-v2"

    if [[ "$DRY_RUN" == "true" ]]; then
        log_warn "Running in DRY-RUN mode — no requests will be sent."
    fi

    local pass=0 fail=0 skip=0

    for name in "${WEBHOOK_ORDER[@]}"; do
        local var_name="${WEBHOOK_MAP[$name]}"
        local url="${!var_name:-}"

        echo ""
        log_info "Testing: ${BOLD}${name}${RESET} (${var_name})"

        if [[ -z "$url" || "$url" == "https://hooks.slack.com/..."* || "$url" == "https://discord.com/..."* ]]; then
            log_warn "Not configured — skipping (set ${var_name} in manifest)"
            (( skip++ )) || true
            continue
        fi

        # Determine severity label for payload colouring
        local severity
        case "$name" in
            critical)      severity="critical" ;;
            warning)       severity="warning"  ;;
            backup-failure) severity="backup"  ;;
            *)             severity="info"     ;;
        esac

        if send_webhook "$name" "$url" "$severity"; then
            (( pass++ )) || true
        else
            (( fail++ )) || true
        fi
    done

    # ─── Summary ──────────────────────────────────────────────────────────────
    echo ""
    log_header "Summary"
    echo -e "  ${GREEN}Passed${RESET}:  ${pass}"
    echo -e "  ${RED}Failed${RESET}:  ${fail}"
    echo -e "  ${YELLOW}Skipped${RESET}: ${skip} (not configured)"
    echo ""

    if [[ $fail -gt 0 ]]; then
        log_fail "One or more webhooks failed. Check URLs and network access."
        exit 1
    elif [[ $pass -eq 0 && $skip -gt 0 ]]; then
        log_warn "No webhooks configured. Set URLs in your manifest and re-run."
        exit 0
    else
        log_ok "All configured webhooks reachable."
        exit 0
    fi
}

main "$@"
