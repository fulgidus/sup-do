#!/usr/bin/env bash
set -euo pipefail

# --- Wrapper cross-platform per date con supporto nanosecondi ---
_date() {
  if command -v gdate >/dev/null 2>&1; then
    gdate "$@"                      # macOS con coreutils (brew install coreutils)
  elif date +%N >/dev/null 2>&1 && [[ "$(date +%N)" != "N" ]]; then
    date "$@"                       # Linux / GNU coreutils nativo
  else
    # macOS senza coreutils: niente %N, fallback a precisione al secondo
    local fmt="$*"
    fmt="${fmt//.%[0-9]N/}"           # rimuove .%5N, .%3N, .%9N, ecc.
    fmt="${fmt//.%N/}"                # rimuove .%N nudo
    fmt="${fmt//%[0-9]N/}"           # rimuove %5N, %3N, %9N, ecc.
    fmt="${fmt//%N/}"                # rimuove %N nudo
    date "$fmt"
  fi
}

# --- Config ---
SUPABASE_URL="https://${PROJECT_REF}.supabase.co"
REST_URL="${SUPABASE_URL}/rest/v1/audit_logs"
LOG="$HOME/.local/state/sup-do.log"
SOURCE_ID=666
LEVEL="debug"
mkdir -p "$(dirname "$LOG")"

# --- Timestamp reale di inizio esecuzione ---
START_TS=$(_date +"%Y-%m-%dT%H:%M:%S.%5N%:z")
START_EPOCH=$(_date +%s.%N)
HOUR=$(_date +%H)
YEAR=$(_date +%Y)
MONTH=$(_date +%B)
MINUTE=$(_date +%M)
SECOND=$(_date +%S)
TZ_LABEL="$(_date +%Z) (UTC$(_date +%:z))"
DOW=$(_date +%A)
DOM=$(_date +%d)
READABLE_DATE=$(_date +"%-d %B %Y")
READABLE_TIME=$(_date +"%-I:%M:%S %p (%H:%M:%S)")

# --- Info macchina ---
UPTIME_SECONDS=$(awk '{print int($1)}' /proc/uptime)
LOAD_AVG=$(awk '{print $1", "$2", "$3}' /proc/loadavg)
CPU_CORES=$(nproc)
MEM_TOTAL_KB=$(awk '/MemTotal/{print $2}' /proc/meminfo)
MEM_AVAIL_KB=$(awk '/MemAvailable/{print $2}' /proc/meminfo)
RAM_USED_PCT=$(awk -v t="${MEM_TOTAL_KB:-0}" -v a="${MEM_AVAIL_KB:-0}" 'BEGIN{ if (t+0==0) {print "0.0"} else {printf "%.1f", (t-a)/t*100} }')
HOSTNAME=$(hostname)

MESSAGE="Keep alive event started at ${START_TS}"

# --- Costruzione payload JSON (via jq, evita problemi di escaping) ---
PAYLOAD=$(jq -n \
  --arg hour "$HOUR" \
  --arg year "$YEAR" \
  --arg month "$MONTH" \
  --arg minute "$MINUTE" \
  --arg second "$SECOND" \
  --arg tz "$TZ_LABEL" \
  --arg timestamp "$START_TS" \
  --arg dow "$DOW" \
  --arg dom "$DOM" \
  --arg readable_date "$READABLE_DATE" \
  --arg readable_time "$READABLE_TIME" \
  --arg hostname "$HOSTNAME" \
  --argjson uptime_seconds "$UPTIME_SECONDS" \
  --arg load_avg "$LOAD_AVG" \
  --argjson cpu_cores "$CPU_CORES" \
  --arg ram_used_pct "$RAM_USED_PCT" \
  '{
    "Hour": $hour,
    "Year": $year,
    "Month": $month,
    "Minute": $minute,
    "Second": $second,
    "Timezone": $tz,
    "timestamp": $timestamp,
    "Day of week": $dow,
    "Day of month": $dom,
    "Readable date": $readable_date,
    "Readable time": $readable_time,
    "hostname": $hostname,
    "uptime_seconds": $uptime_seconds,
    "load_avg_1_5_15": $load_avg,
    "cpu_cores": $cpu_cores,
    "ram_used_pct": $ram_used_pct
  }')

BODY=$(jq -n \
  --arg source "$SOURCE_ID" \
  --arg level "$LEVEL" \
  --arg message "$MESSAGE" \
  --argjson payload "$PAYLOAD" \
  '{source: ($source | tonumber), level: $level, message: $message, payload: $payload}')

# --- Invio ---
http_code=$(curl -s -o /tmp/sup-do-response.json -w '%{http_code}' \
  -X POST "$REST_URL" \
  -H "apikey: ${SUPABASE_SECRET_KEY}" \
  -H "Content-Type: application/json" \
  -H "Prefer: return=minimal" \
  -d "$BODY")

END_EPOCH=$(date +%s.%N)
ELAPSED=$(awk -v s="$START_EPOCH" -v e="$END_EPOCH" 'BEGIN{printf "%.4f", e-s}')

echo "${START_TS} audit insert status=${http_code} elapsed=${ELAPSED}s" >> "$LOG"

if [[ "$http_code" -ge 300 ]]; then
  echo "Response: $(cat /tmp/sup-do-response.json)" >> "$LOG"
  else
  rm -f /tmp/sup-do-response.json
fi