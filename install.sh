#!/usr/bin/env bash
set -euo pipefail

REPO="fulgidus/sup-do"
BRANCH="main"
RAW_BASE="https://raw.githubusercontent.com/${REPO}/${BRANCH}"
CONFIG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}"
BIN_DIR="${HOME}/.local/bin"
STATE_DIR="${XDG_STATE_HOME:-$HOME/.local/state}"
ENV_FILE="${CONFIG_DIR}/sup-do.env"
SCRIPT="${BIN_DIR}/sup-do.sh"
LOG="${STATE_DIR}/sup-do.log"

detect_os() {
  case "$(uname -s)" in
    Linux)  echo "linux" ;;
    Darwin) echo "macos" ;;
    *)      echo "unsupported" ;;
  esac
}

ensure_deps() {
  local missing=()
  command -v curl >/dev/null 2>&1 || missing+=("curl")
  command -v jq   >/dev/null 2>&1 || missing+=("jq")

  if [[ "$(detect_os)" == "macos" ]]; then
    command -v gdate >/dev/null 2>&1 || echo "  [warn] coreutils not installed — timestamps will be second-precision only"
  fi

  if [[ ${#missing[@]} -gt 0 ]]; then
    echo "  [error] missing: ${missing[*]}. Install first, then re-run."
    exit 1
  fi
}

rest_api() {
  local method="$1" path="$2" body="${3:-}"
  local url="https://${PROJECT_REF}.supabase.co/rest/v1/${path}"
  local args=(-s -X "$method" -w '%{http_code}' -o /tmp/sup-do-api-resp.json \
    -H "apikey: ${SUPABASE_SECRET_KEY}" \
    -H "Content-Type: application/json")

  # Prefer header is only useful for POST; skip for GET/HEAD
  if [[ "$method" == "POST" ]]; then
    args+=(-H "Prefer: return=minimal")
  fi

  if [[ -n "$body" ]]; then
    args+=(-d "$body")
  fi

  curl "${args[@]}" "$url" 2>/dev/null
}

check_table() {
  local table="$1"
  local code
  code=$(rest_api "GET" "${table}?select=id&limit=1")
  echo "$code"
}

load_env() {
  set +u
  set -a
  source "$ENV_FILE"
  set +a
  set -u
}

setup_config() {
  if [[ -f "$ENV_FILE" ]]; then
    echo "  [found] $ENV_FILE"
    load_env
    return 0
  fi

  echo "  Creating $ENV_FILE from template..."
  curl -fsSL "${RAW_BASE}/src/sup-do.example.env" -o "$ENV_FILE"
  chmod 600 "$ENV_FILE"

  echo ""
  echo "  ================================================"
  echo "  Edit $ENV_FILE — fill in your Supabase values:"
  echo ""
  echo "    SUPABASE_SECRET_KEY=<your_sb_secret_xxx>"
  echo "    PROJECT_REF=<your_project_ref>"
  echo "  ================================================"
  echo ""

  if [[ -t 0 && -t 1 ]]; then
    read -r -p "  Open editor now? [Y/n] " yn
    yn="${yn:-y}"
    if [[ "$yn" =~ ^[Yy]$ ]]; then
      "${EDITOR:-nano}" "$ENV_FILE"
    fi
  fi

  load_env
}

validate_config() {
  if [[ -z "${SUPABASE_SECRET_KEY:-}" || "$SUPABASE_SECRET_KEY" == *"<SUPABASE_SECRET_KEY>" ]]; then
    echo "  [error] SUPABASE_SECRET_KEY not set in $ENV_FILE"
    exit 1
  fi
  if [[ -z "${PROJECT_REF:-}" || "$PROJECT_REF" == *"<PROJECT_REF>" ]]; then
    echo "  [error] PROJECT_REF not set in $ENV_FILE"
    exit 1
  fi
}

setup_tables() {
  local audit_code

  echo "  Checking Supabase tables..."
  audit_code=$(check_table "audit_logs")

  if [[ "$audit_code" == "404" ]]; then
    echo ""
    echo "  [setup] Tables not found. Run this SQL in your Supabase Dashboard SQL editor:"
    echo ""
    echo "    create table public.log_sources ("
    echo "      id bigint primary key,"
    echo "      created_at timestamptz not null default now(),"
    echo "      name text not null,"
    echo "      description text"
    echo "    );"
    echo ""
    echo "    create table public.audit_logs ("
    echo "      id uuid primary key default gen_random_uuid(),"
    echo "      created_at timestamptz not null default now(),"
    echo "      source bigint references public.log_sources(id),"
    echo "      level varchar not null,"
    echo "      message text,"
    echo "      payload jsonb"
    echo "    );"
    echo ""
    if [[ -t 0 && -t 1 ]]; then
      read -r -p "  Press Enter after you've run the SQL..."
    fi

    # Re-check
    audit_code=$(check_table "audit_logs")
    if [[ "$audit_code" == "404" ]]; then
      echo "  [error] Tables still not found. Re-run installer after creating them."
      exit 1
    fi
    echo "  [ok] Tables created."
  else
    echo "  [ok] audit_logs table exists (HTTP $audit_code)."
  fi

  # Now check log_sources for picking/creating a source
  local src_code
  src_code=$(rest_api "GET" "log_sources?select=id&limit=1")

  if [[ "$src_code" == "404" ]]; then
    echo "  [setup] log_sources table missing — run the SQL above and re-run."
    exit 1
  fi

  # Fetch all sources for display
  local sources_json
  sources_json=$(curl -s "https://${PROJECT_REF}.supabase.co/rest/v1/log_sources?select=id,name,description&order=id.asc" \
    -H "apikey: ${SUPABASE_SECRET_KEY}")

  if [[ -n "${SOURCE_ID:-}" ]]; then
    echo "  [ok] SOURCE_ID=${SOURCE_ID} already configured."
    return
  fi

  local count
  count=$(echo "$sources_json" | jq 'length')

  if [[ "$count" -gt 0 ]]; then
    echo ""
    echo "  Existing log sources:"
    echo "$sources_json" | jq -r '.[] | "    \(.id)  \(.name) — \(.description // "-")"'
    echo ""
    echo "  Options:"
    echo "    1) Pick an existing source"
    echo "    2) Create a new source"

    if [[ ! -t 0 ]]; then
      echo "  [error] Interactive input required. Set SOURCE_ID manually in $ENV_FILE and re-run."
      exit 1
    fi

    read -r -p "  Choose [1/2]: " choice
    case "$choice" in
      2) create_source ;;
      *)
        read -r -p "  Enter source ID: " sid
        SOURCE_ID="$sid"
        ;;
    esac
  else
    echo "  No log sources found. Creating one..."
    create_source
  fi

  # Save SOURCE_ID to env file
  echo "" >> "$ENV_FILE"
  echo "# Auto-detected by installer" >> "$ENV_FILE"
  echo "SOURCE_ID=${SOURCE_ID}" >> "$ENV_FILE"
  echo "  [ok] SOURCE_ID=${SOURCE_ID} saved to $ENV_FILE"
}

create_source() {
  local name desc

  if [[ ! -t 0 ]]; then
    # Non-interactive: auto-create with hostname
    SOURCE_ID=$(($(date +%s) % 1000000))
  else
    read -r -p "  Source name (default: $(hostname)): " name
    name="${name:-$(hostname)}"
    read -r -p "  Description: " desc
    SOURCE_ID=$(($(date +%s) % 1000000))
  fi

  local body
  body=$(jq -n \
    --argjson id "$SOURCE_ID" \
    --arg name "$name" \
    --arg desc "${desc:-}" \
    '{id: $id, name: $name, description: $desc}')

  echo "  Creating source '${name}' (ID: ${SOURCE_ID})..."
  local code
  code=$(rest_api "POST" "log_sources" "$body")
  if [[ "$code" -ge 300 ]]; then
    echo "  [error] Failed to create source (HTTP $code)"
    cat /tmp/sup-do-api-resp.json
    exit 1
  fi
  echo "  [ok] Source created."
}

install_linux() {
  local UNIT_DIR="${CONFIG_DIR}/systemd/user"
  mkdir -p "$UNIT_DIR" "$BIN_DIR"

  echo "  Installing script → $SCRIPT"
  curl -fsSL "${RAW_BASE}/src/sup-do.sh" -o "$SCRIPT"
  chmod +x "$SCRIPT"

  echo "  Installing service → ${UNIT_DIR}/sup-do.service"
  curl -fsSL "${RAW_BASE}/src/sup-do.service" -o "${UNIT_DIR}/sup-do.service"

  echo "  Installing timer   → ${UNIT_DIR}/sup-do.timer"
  curl -fsSL "${RAW_BASE}/src/sup-do.timer" -o "${UNIT_DIR}/sup-do.timer"

  systemctl --user daemon-reload
  systemctl --user enable --now sup-do.timer
  systemctl --user list-timers sup-do.timer
}

install_macos() {
  local LAUNCH_AGENTS_DIR="${HOME}/Library/LaunchAgents"
  mkdir -p "$LAUNCH_AGENTS_DIR" "$BIN_DIR"

  echo "  Installing script → $SCRIPT"
  curl -fsSL "${RAW_BASE}/src/sup-do.sh" -o "$SCRIPT"
  chmod +x "$SCRIPT"

  echo "  Installing plist  → ${LAUNCH_AGENTS_DIR}/com.sup-do.plist"
  curl -fsSL "${RAW_BASE}/src/com.sup-do.plist" -o "${LAUNCH_AGENTS_DIR}/com.sup-do.plist"

  launchctl load "${LAUNCH_AGENTS_DIR}/com.sup-do.plist"
  echo "  Loaded. Runs at 04:00 / 10:00 / 16:00 / 22:00 local time."
}

remove_linux() {
  local UNIT_DIR="${CONFIG_DIR}/systemd/user"

  echo "  Stopping & disabling timer..."
  systemctl --user stop sup-do.timer 2>/dev/null || true
  systemctl --user disable sup-do.timer 2>/dev/null || true

  rm -f "${UNIT_DIR}/sup-do.service" "${UNIT_DIR}/sup-do.timer"
  systemctl --user daemon-reload

  rm -f "$SCRIPT"
  rm -f "$ENV_FILE"
  echo "  Removed."
}

remove_macos() {
  local PLIST="${HOME}/Library/LaunchAgents/com.sup-do.plist"

  echo "  Unloading launchd job..."
  launchctl unload "$PLIST" 2>/dev/null || true

  rm -f "$PLIST"
  rm -f "$SCRIPT"
  rm -f "$ENV_FILE"
  echo "  Removed."
}

usage() {
  cat <<EOF
sup-do — Supabase free-tier keepalive

Install:
  curl -fsSL https://raw.githubusercontent.com/${REPO}/${BRANCH}/install.sh | bash

Options:
  -r    Remove sup-do (deactivates timer, deletes files, drops config)
  -h    Show this help

The installer will:
  1. Check for curl, jq
  2. Create ~/.config/sup-do.env (prompts for keys)
  3. Verify Supabase tables exist (prompts SQL if missing)
  4. List existing log sources or create one
  5. Install the timer/launchd job

EOF
  exit 0
}

# --- main ---
REMOVE=false

while getopts "rh" opt; do
  case "$opt" in
    r) REMOVE=true ;;
    h) usage ;;
    *) usage ;;
  esac
done

echo "==> sup-do — Supabase keepalive"
echo ""

OS="$(detect_os)"
if [[ "$OS" == "unsupported" ]]; then
  echo "  Unsupported OS: $(uname -s)"
  exit 1
fi

if $REMOVE; then
  case "$OS" in
    linux) remove_linux ;;
    macos) remove_macos ;;
  esac
  exit 0
fi

echo "  OS: $OS"
echo ""

ensure_deps
setup_config
validate_config
echo ""

setup_tables
echo ""

case "$OS" in
  linux)  install_linux ;;
  macos)  install_macos ;;
esac

echo ""
echo "==> Done. Manual test:"
echo ""

if [[ "$OS" == "linux" ]]; then
  echo "  systemctl --user start sup-do.service"
  echo "  cat $LOG"
else
  echo "  launchctl start com.sup-do"
  echo "  cat $LOG"
fi

echo ""
echo "  Expected: 'audit insert status=201 elapsed=...'"
