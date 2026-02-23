#!/usr/bin/env bash
set -euo pipefail

TITLE="${CODEX_WARP_TITLE:-Codex}"
MAX_LEN="${CODEX_WARP_MAX_LEN:-200}"
FORCE_WARP="${CODEX_WARP_FORCE:-0}"
TTY_OVERRIDE="${CODEX_WARP_TTY:-}"
DEBUG="${CODEX_WARP_DEBUG:-0}"
CHANNEL="${CODEX_WARP_CHANNEL:-auto}"
PAYLOAD="${1:-}"

normalize_text() {
  tr '\r\n' ' ' | tr -s '[:space:]' ' ' | sed -E 's/^ +| +$//g'
}

sanitize_for_osc() {
  # Drop control characters that can break OSC messages.
  LC_ALL=C tr '\000-\010\013\014\016-\037\177' ' ' | tr -s '[:space:]' ' '
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

if not isinstance(data, dict):
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

log_debug() {
  if [ "$DEBUG" = "1" ]; then
    printf '[warp-notify] %s\n' "$1" >&2
  fi
}

can_open_for_write() {
  local path="$1"

  # Restrict to writable character devices to avoid clobbering regular files.
  if [ -z "$path" ] || [ ! -c "$path" ] || [ ! -w "$path" ]; then
    return 1
  fi

  # Confirm we can actually open the device in this runtime.
  if ! { exec 3>>"$path"; } 2>/dev/null; then
    return 1
  fi
  exec 3>&-

  return 0
}

resolve_tty_target() {
  local tmux_tty=""
  local parent_tty=""
  local candidate=""

  if can_open_for_write "$TTY_OVERRIDE"; then
    printf "%s" "$TTY_OVERRIDE"
    return 0
  fi

  if can_open_for_write "/dev/tty"; then
    printf "/dev/tty"
    return 0
  fi

  if [ -n "${TMUX:-}" ] && command -v tmux >/dev/null 2>&1; then
    tmux_tty="$(tmux display-message -p '#{pane_tty}' 2>/dev/null || true)"
    if can_open_for_write "$tmux_tty"; then
      printf "%s" "$tmux_tty"
      return 0
    fi
  fi

  if can_open_for_write "${SSH_TTY:-}"; then
    printf "%s" "${SSH_TTY}"
    return 0
  fi

  parent_tty="$(ps -o tty= -p "${PPID:-0}" 2>/dev/null | tr -d '[:space:]' || true)"
  if [ -n "$parent_tty" ] && [ "$parent_tty" != "??" ] && [ "$parent_tty" != "?" ]; then
    candidate="/dev/$parent_tty"
    if can_open_for_write "$candidate"; then
      printf "%s" "$candidate"
      return 0
    fi
  fi

  return 1
}

is_warp_terminal() {
  if [ "$FORCE_WARP" = "1" ]; then
    return 0
  fi

  if [ "${TERM_PROGRAM:-}" = "WarpTerminal" ]; then
    return 0
  fi

  if [ -n "${WARP_SESSION_ID:-}" ] || [ -n "${WARP_IS_LOCAL_SHELL_SESSION:-}" ]; then
    return 0
  fi

  return 1
}

emit_notification() {
  local title="$1"
  local body="$2"
  local tty_target=""
  local selected_channel="$CHANNEL"

  if ! tty_target="$(resolve_tty_target)"; then
    log_debug "No writable terminal target found; skipping notification."
    return 0
  fi

  selected_channel="$(printf "%s" "$selected_channel" | tr '[:upper:]' '[:lower:]')"
  if [ "$selected_channel" = "auto" ]; then
    # Claude-style default: Warp in-app toast via OSC 9.
    selected_channel="osc9"
  fi

  case "$selected_channel" in
    osc9)
      log_debug "Sending OSC 9 notification to $tty_target"
      printf '\033]9;%s\007' "$body" >"$tty_target" 2>/dev/null || true
      ;;
    osc777)
      if is_warp_terminal; then
        log_debug "Sending Warp OSC 777 notification to $tty_target"
        printf '\033]777;notify;%s;%s\007' "$title" "$body" >"$tty_target" 2>/dev/null || true
      else
        log_debug "OSC 777 requested, but terminal is not Warp; falling back to OSC 9"
        printf '\033]9;%s\007' "$body" >"$tty_target" 2>/dev/null || true
      fi
      ;;
    both)
      log_debug "Sending OSC 9 + OSC 777 notifications to $tty_target"
      printf '\033]9;%s\007' "$body" >"$tty_target" 2>/dev/null || true
      if is_warp_terminal; then
        printf '\033]777;notify;%s;%s\007' "$title" "$body" >"$tty_target" 2>/dev/null || true
      fi
      ;;
    *)
      log_debug "Unknown CODEX_WARP_CHANNEL=$selected_channel; defaulting to OSC 9"
      printf '\033]9;%s\007' "$body" >"$tty_target" 2>/dev/null || true
      ;;
  esac
}

if [ "${1:-}" = "--test" ]; then
  PAYLOAD='{"type":"agent-turn-complete","input-messages":["Test notification"],"last-assistant-message":"Codex notify hook is connected."}'
fi

if ! [[ "$MAX_LEN" =~ ^[0-9]+$ ]]; then
  MAX_LEN=200
fi

TITLE="$(printf "%s" "$TITLE" | normalize_text | sanitize_for_osc)"
MESSAGE="$(extract_message "$PAYLOAD" | normalize_text | sanitize_for_osc)"
MESSAGE="$(truncate_text "$MESSAGE" "$MAX_LEN")"

emit_notification "$TITLE" "$MESSAGE"
