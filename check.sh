#!/usr/bin/env bash
# Uptime checker with WhatsApp alerts (via CallMeBot).
# Alerts once when a site goes DOWN and once when it RECOVERS — no spam every run.
#
# Required env vars:
#   SITES          URLs to check, separated by spaces or new lines
# Plus at least one way to send alerts:
#   A) CallMeBot, one or more people (free, each person activates CallMeBot once)
#      WA_RECIPIENTS  "phone:apikey" pairs separated by spaces,
#                     e.g. "919876543210:123456 918765432109:654321"
#      (or the older single-person form: WA_PHONE + WA_APIKEY)
#   B) A real WhatsApp group via Whapi.Cloud (paid gateway)
#      WHAPI_TOKEN     your Whapi.Cloud channel token
#      WHAPI_GROUP_ID  the group's ID, e.g. 120363012345678901@g.us
# Optional:
#   STATE_DIR   where up/down state is remembered between runs (default .uptime-state)
#   RETRIES     attempts before declaring a site down (default 3)
#   TIMEOUT     seconds per attempt (default 15)

set -uo pipefail

: "${SITES:?Set SITES}"
WA_RECIPIENTS="${WA_RECIPIENTS:-}"
if [[ -n "${WA_PHONE:-}" && -n "${WA_APIKEY:-}" ]]; then
  WA_RECIPIENTS="$WA_RECIPIENTS $WA_PHONE:$WA_APIKEY"
fi
WHAPI_TOKEN="${WHAPI_TOKEN:-}"
WHAPI_GROUP_ID="${WHAPI_GROUP_ID:-}"
if [[ -z "${WA_RECIPIENTS// /}" && ( -z "$WHAPI_TOKEN" || -z "$WHAPI_GROUP_ID" ) ]]; then
  echo "Set WA_RECIPIENTS (or WA_PHONE + WA_APIKEY), or WHAPI_TOKEN + WHAPI_GROUP_ID" >&2
  exit 1
fi
STATE_DIR="${STATE_DIR:-.uptime-state}"
RETRIES="${RETRIES:-3}"
TIMEOUT="${TIMEOUT:-15}"

mkdir -p "$STATE_DIR"

now() { TZ=Asia/Kolkata date '+%d %b %Y, %I:%M %p IST'; }

send_whatsapp() {
  local msg=$1 pair
  # A) CallMeBot: one message per person
  for pair in $WA_RECIPIENTS; do
    curl -sS -G --max-time 20 "https://api.callmebot.com/whatsapp.php" \
      --data-urlencode "phone=${pair%%:*}" \
      --data-urlencode "apikey=${pair#*:}" \
      --data-urlencode "text=$msg" >/dev/null \
      || echo "  ! CallMeBot alert failed for ${pair%%:*}"
  done
  # B) Whapi.Cloud: one message to the group
  if [[ -n "$WHAPI_TOKEN" && -n "$WHAPI_GROUP_ID" ]]; then
    jq -n --arg to "$WHAPI_GROUP_ID" --arg body "$msg" '{to: $to, body: $body}' |
      curl -sS --fail --max-time 20 "https://gate.whapi.cloud/messages/text" \
        -H "Authorization: Bearer $WHAPI_TOKEN" \
        -H "Content-Type: application/json" \
        --data-binary @- >/dev/null \
      || echo "  ! Group alert failed to send"
  fi
}

# Prints the last HTTP code; returns 0 if the site answered 2xx/3xx.
check_site() {
  local url=$1 code="000" i
  for ((i = 1; i <= RETRIES; i++)); do
    code=$(curl -s -o /dev/null -L --max-time "$TIMEOUT" -w '%{http_code}' "$url") || true
    [[ $code =~ ^[23] ]] && { echo "$code"; return 0; }
    ((i < RETRIES)) && sleep 10
  done
  echo "$code"
  return 1
}

for url in $SITES; do
  key=$(printf '%s' "$url" | sha1sum | cut -c1-12)
  state_file="$STATE_DIR/$key"
  previous=$(cat "$state_file" 2>/dev/null || echo "up")

  if code=$(check_site "$url"); then
    echo "UP    $url ($code)"
    if [[ $previous == "down" ]]; then
      send_whatsapp "✅ RECOVERED: $url is back up (HTTP $code) — $(now)"
    fi
    echo "up" >"$state_file"
  else
    reason="HTTP $code"
    [[ $code == "000" ]] && reason="no response / timeout"
    echo "DOWN  $url ($reason)"
    if [[ $previous != "down" ]]; then
      send_whatsapp "🔴 DOWN: $url — $reason — $(now)"
    fi
    echo "down" >"$state_file"
  fi
done

exit 0
