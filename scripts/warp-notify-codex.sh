#!/usr/bin/env bash
set -euo pipefail

TITLE="${CODEX_WARP_TITLE:-Codex}"
MAX_LEN="${CODEX_WARP_MAX_LEN:-200}"
PAYLOAD="${1:-}"

normalize_text() {
  tr '\r\n' ' ' | tr -s '[:space:]' ' ' | sed -E 's/^ +| +$//g'
}

truncate_text() {
  local text="$1"
  local limit="$2"

  if [ "$limit" -lt 4 ]; then
    printf "%s" "$text"
    return 0
  fi

  if [ "${#text}" -le "$limit" ]; then
    printf "%s" "$text"
  else
    printf "%s..." "${text:0:$((limit - 3))}"
  fi
}

extract_message() {
  local payload="$1"

  if [ -z "$payload" ]; then
    printf "Agent turn complete"
    return 0
  fi

  if command -v python3 >/dev/null 2>&1; then
    python3 - "$payload" <<'PY'
import json
import sys

raw = sys.argv[1]

try:
    data = json.loads(raw)
except Exception:
    print(raw.strip() or "Agent turn complete")
    raise SystemExit(0)

assistant = (data.get("last-assistant-message") or "").strip()
if assistant:
    print(assistant)
    raise SystemExit(0)

inputs = data.get("input-messages") or []
first_input = ""
if isinstance(inputs, list) and inputs:
    first_input = str(inputs[0]).strip()

if first_input:
    print(f'Completed: "{first_input}"')
else:
    print("Agent turn complete")
PY
    return 0
  fi

  # Fallback without python3.
  printf "%s" "$payload"
}

emit_notification() {
  local title="$1"
  local body="$2"

  # Notification escape sequences need a controlling terminal.
  if ! tty -s; then
    return 0
  fi
  local tty_target="/dev/tty"

  if [ "${TERM_PROGRAM:-}" = "WarpTerminal" ]; then
    # Warp native notification channel.
    printf '\033]777;notify;%s;%s\007' "$title" "$body" >"$tty_target" || true
  else
    # Generic OSC 9 fallback for terminals that support it.
    printf '\033]9;%s\007' "$body" >"$tty_target" || true
  fi
}

if [ "${1:-}" = "--test" ]; then
  PAYLOAD='{"type":"agent-turn-complete","input-messages":["Test notification"],"last-assistant-message":"Codex notify hook is connected."}'
fi

MESSAGE="$(extract_message "$PAYLOAD" | normalize_text)"
MESSAGE="$(truncate_text "$MESSAGE" "$MAX_LEN")"

emit_notification "$TITLE" "$MESSAGE"
