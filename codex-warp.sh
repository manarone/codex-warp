#!/usr/bin/env bash
# Codex notify hook that emits Warp-compatible OSC notifications.
set -euo pipefail

SCRIPT_SOURCE="${BASH_SOURCE[0]}"
case "$SCRIPT_SOURCE" in
  */*)
    SCRIPT_DIR="$(cd "${SCRIPT_SOURCE%/*}" && pwd -P)"
    ;;
  *)
    SCRIPT_DIR="$(pwd -P)"
    ;;
esac
SCRIPT_PATH="$SCRIPT_DIR/${SCRIPT_SOURCE##*/}"
DEFAULT_TEST_PAYLOAD='{"type":"agent-turn-complete","input-messages":["Test notification"],"last-assistant-message":"Codex notify hook is connected."}'
TITLE="${CODEX_WARP_TITLE:-Codex}"
MAX_LEN="${CODEX_WARP_MAX_LEN:-200}"
FORCE_WARP="${CODEX_WARP_FORCE:-0}"
TTY_OVERRIDE="${CODEX_WARP_TTY:-}"
DEBUG="${CODEX_WARP_DEBUG:-0}"
CHANNEL="${CODEX_WARP_CHANNEL:-auto}"

print_usage() {
  cat <<EOF
Usage:
  ${SCRIPT_PATH##*/} [payload-json-or-text]
  ${SCRIPT_PATH##*/} --test
  ${SCRIPT_PATH##*/} --doctor [--send-test]

Options:
  --test       Send a built-in sample notification payload.
  --doctor     Print environment and config diagnostics for this hook.
  --send-test  With --doctor, also send an OSC 9 + OSC 777 sample notification.
  --help       Show this help text.
EOF
}

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

  if [ "$limit" -le 0 ]; then
    return 0
  fi

  if [ "$limit" -lt 4 ]; then
    printf "%s" "${text:0:$limit}"
    return 0
  fi

  if [ "${#text}" -le "$limit" ]; then
    printf "%s" "$text"
  else
    printf "%s..." "${text:0:$((limit - 3))}"
  fi
}

sanitize_for_osc777_field() {
  # Warp's OSC 777 parser uses ';' as a field delimiter, so semicolons in the
  # title/body need to be normalized before interpolation.
  tr ';' ','
}

extract_message_with_python() {
  local payload="$1"
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
}

extract_message_with_perl() {
  local payload="$1"
  perl -MJSON::PP -e '
    my $raw = shift;
    my $data = eval { JSON::PP::decode_json($raw) };
    if ($@ || ref($data) ne "HASH") {
      $raw =~ s/^\s+|\s+$//g;
      print length($raw) ? $raw : "Agent turn complete";
      exit 0;
    }

    my $assistant = $data->{"last-assistant-message"} // "";
    $assistant =~ s/^\s+|\s+$//g;
    if (length($assistant)) {
      print $assistant;
      exit 0;
    }

    my $inputs = $data->{"input-messages"};
    my $first_input = "";
    if (ref($inputs) eq "ARRAY" && @{$inputs}) {
      $first_input = defined $inputs->[0] ? "$inputs->[0]" : "";
      $first_input =~ s/^\s+|\s+$//g;
    }

    if (length($first_input)) {
      print qq{Completed: "$first_input"};
    } else {
      print "Agent turn complete";
    }
  ' "$payload"
}

extract_message_with_node() {
  local payload="$1"
  node -e '
    const raw = process.argv[1];

    let data;
    try {
      data = JSON.parse(raw);
    } catch {
      console.log(raw.trim() || "Agent turn complete");
      process.exit(0);
    }

    if (!data || typeof data !== "object" || Array.isArray(data)) {
      console.log(raw.trim() || "Agent turn complete");
      process.exit(0);
    }

    const assistant = String(data["last-assistant-message"] || "").trim();
    if (assistant) {
      console.log(assistant);
      process.exit(0);
    }

    const inputs = Array.isArray(data["input-messages"]) ? data["input-messages"] : [];
    const firstInput = inputs.length ? String(inputs[0] ?? "").trim() : "";
    console.log(firstInput ? `Completed: "${firstInput}"` : "Agent turn complete");
  ' "$payload"
}

extract_message_with_ruby() {
  local payload="$1"
  ruby -rjson -e '
    raw = ARGV[0]

    begin
      data = JSON.parse(raw)
    rescue StandardError
      text = raw.to_s.strip
      puts(text.empty? ? "Agent turn complete" : text)
      exit 0
    end

    unless data.is_a?(Hash)
      text = raw.to_s.strip
      puts(text.empty? ? "Agent turn complete" : text)
      exit 0
    end

    assistant = data.fetch("last-assistant-message", "").to_s.strip
    if !assistant.empty?
      puts assistant
      exit 0
    end

    inputs = data["input-messages"].is_a?(Array) ? data["input-messages"] : []
    first_input = inputs.empty? ? "" : inputs[0].to_s.strip
    puts(first_input.empty? ? "Agent turn complete" : %{Completed: "#{first_input}"})
  ' "$payload"
}

extract_message_with_jq() {
  local payload="$1"
  printf "%s" "$payload" | jq -r '
    def fallback:
      (tostring | gsub("^\\s+|\\s+$"; "")) as $text
      | if ($text | length) > 0 then $text else "Agent turn complete" end;

    try (
      if type != "object" then
        fallback
      elif (.["last-assistant-message"] // "" | tostring | gsub("^\\s+|\\s+$"; "")) as $assistant | ($assistant | length) > 0 then
        $assistant
      else
        (.["input-messages"] // []) as $inputs
        | if ($inputs | type) == "array" and ($inputs | length) > 0 then
            ($inputs[0] | tostring | gsub("^\\s+|\\s+$"; "")) as $first
            | if ($first | length) > 0 then "Completed: \"\($first)\"" else "Agent turn complete" end
          else
            "Agent turn complete"
          end
      end
    ) catch fallback
  ' 2>/dev/null
}

extract_message() {
  local payload="$1"

  if [ -z "$payload" ]; then
    printf "Agent turn complete"
    return 0
  fi

  if command -v python3 >/dev/null 2>&1; then
    extract_message_with_python "$payload"
    return 0
  fi

  if command -v perl >/dev/null 2>&1; then
    extract_message_with_perl "$payload"
    return 0
  fi

  if command -v node >/dev/null 2>&1; then
    extract_message_with_node "$payload"
    return 0
  fi

  if command -v ruby >/dev/null 2>&1; then
    extract_message_with_ruby "$payload"
    return 0
  fi

  if command -v jq >/dev/null 2>&1; then
    extract_message_with_jq "$payload"
    return 0
  fi

  # Fallback without any available JSON parser.
  printf "%s" "$payload"
}

log_debug() {
  if [ "$DEBUG" = "1" ]; then
    printf '[codex-warp] %s\n' "$1" >&2
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

resolve_notification_channel() {
  local selected_channel="$1"

  selected_channel="$(printf "%s" "$selected_channel" | tr '[:upper:]' '[:lower:]')"
  if [ "$selected_channel" = "auto" ]; then
    if is_warp_terminal; then
      selected_channel="both"
    else
      selected_channel="osc9"
    fi
  fi

  printf "%s" "$selected_channel"
}

read_payload() {
  local payload="${1:-}"

  if [ -n "$payload" ]; then
    printf "%s" "$payload"
    return 0
  fi

  if [ ! -t 0 ]; then
    cat
    return 0
  fi

  return 0
}

config_mentions_script() {
  local config_path="$1"

  if [ ! -f "$config_path" ]; then
    printf "missing"
    return 0
  fi

  if grep -Fq "$SCRIPT_PATH" "$config_path"; then
    printf "exact"
    return 0
  fi

  if grep -Fq "${SCRIPT_PATH##*/}" "$config_path"; then
    printf "basename-only"
    return 0
  fi

  printf "absent"
}

run_doctor() {
  local send_test="${1:-0}"
  local tty_target=""
  local config_path="${HOME:-}/.codex/config.toml"
  local config_status=""
  local warp_status="no"
  local effective_channel=""
  local executable_status="no"

  if is_warp_terminal; then
    warp_status="yes"
  fi

  if [ -x "$SCRIPT_PATH" ]; then
    executable_status="yes"
  fi

  if tty_target="$(resolve_tty_target)"; then
    :
  else
    tty_target="unresolved"
  fi

  effective_channel="$(resolve_notification_channel "$CHANNEL")"
  config_status="$(config_mentions_script "$config_path")"

  printf 'Warp Notify Doctor\n'
  printf 'script_path: %s\n' "$SCRIPT_PATH"
  printf 'script_executable: %s\n' "$executable_status"
  printf 'term_program: %s\n' "${TERM_PROGRAM:-}"
  printf 'warp_detected: %s\n' "$warp_status"
  printf 'configured_channel: %s\n' "$CHANNEL"
  printf 'effective_channel: %s\n' "$effective_channel"
  printf 'tty_override: %s\n' "${TTY_OVERRIDE:-unset}"
  printf 'resolved_tty: %s\n' "$tty_target"
  printf 'stdin_is_tty: '
  if [ -t 0 ]; then
    printf 'yes\n'
  else
    printf 'no\n'
  fi
  printf 'config_path: %s\n' "$config_path"
  printf 'config_status: %s\n' "$config_status"

  case "$config_status" in
    exact)
      printf 'config_hint: notify hook references this exact script path.\n'
      ;;
    basename-only)
      printf 'config_hint: config mentions the script name, but not this exact path.\n'
      ;;
    absent)
      printf 'config_hint: config exists, but this script path was not found.\n'
      ;;
    missing)
      printf 'config_hint: ~/.codex/config.toml was not found.\n'
      ;;
  esac

  if [ "$tty_target" = "unresolved" ]; then
    printf 'doctor_result: no writable TTY target was found. Set CODEX_WARP_TTY to your Warp pane device.\n'
  elif [ "$effective_channel" = "osc9" ]; then
    printf 'doctor_result: in-app notifications should work. Desktop notifications need CODEX_WARP_CHANNEL=both or osc777.\n'
  else
    printf 'doctor_result: Warp desktop notifications should be available when Warp is unfocused.\n'
  fi

  if [ "$send_test" = "1" ]; then
    printf 'doctor_action: sending sample notifications now.\n'
    emit_notification "$TITLE" "Doctor test from Codex Warp notify." "$tty_target" "both"
  else
    printf 'doctor_action: rerun with --doctor --send-test to send in-app and desktop samples.\n'
  fi
}

emit_notification() {
  local title="$1"
  local body="$2"
  local tty_target="${3:-}"
  local selected_channel="${4:-$CHANNEL}"
  local osc777_title=""
  local osc777_body=""

  if [ -z "$tty_target" ] && ! tty_target="$(resolve_tty_target)"; then
    log_debug "No writable terminal target found; skipping notification."
    return 0
  fi

  selected_channel="$(resolve_notification_channel "$selected_channel")"

  osc777_title="$(printf "%s" "$title" | sanitize_for_osc777_field)"
  osc777_body="$(printf "%s" "$body" | sanitize_for_osc777_field)"

  case "$selected_channel" in
    osc9)
      log_debug "Sending OSC 9 notification to $tty_target"
      printf '\033]9;%s\007' "$body" >"$tty_target" 2>/dev/null || true
      ;;
    osc777)
      if is_warp_terminal; then
        log_debug "Sending Warp OSC 777 notification to $tty_target"
        printf '\033]777;notify;%s;%s\007' "$osc777_title" "$osc777_body" >"$tty_target" 2>/dev/null || true
      else
        log_debug "OSC 777 requested, but terminal is not Warp; falling back to OSC 9"
        printf '\033]9;%s\007' "$body" >"$tty_target" 2>/dev/null || true
      fi
      ;;
    both)
      log_debug "Sending OSC 9 + OSC 777 notifications to $tty_target"
      printf '\033]9;%s\007' "$body" >"$tty_target" 2>/dev/null || true
      if is_warp_terminal; then
        printf '\033]777;notify;%s;%s\007' "$osc777_title" "$osc777_body" >"$tty_target" 2>/dev/null || true
      fi
      ;;
    *)
      log_debug "Unknown CODEX_WARP_CHANNEL=$selected_channel; defaulting to OSC 9"
      printf '\033]9;%s\007' "$body" >"$tty_target" 2>/dev/null || true
      ;;
  esac
}

main() {
  local payload_arg=""
  local payload=""
  local mode="notify"
  local send_test="0"

  while [ "$#" -gt 0 ]; do
    case "$1" in
      --test)
        mode="test"
        ;;
      --doctor)
        mode="doctor"
        ;;
      --send-test)
        send_test="1"
        ;;
      --help|-h)
        print_usage
        return 0
        ;;
      --*)
        printf 'Unknown option: %s\n' "$1" >&2
        print_usage >&2
        return 1
        ;;
      *)
        if [ -n "$payload_arg" ]; then
          printf 'Unexpected extra argument: %s\n' "$1" >&2
          print_usage >&2
          return 1
        fi
        payload_arg="$1"
        ;;
    esac
    shift
  done

  if [ "$mode" = "doctor" ]; then
    run_doctor "$send_test"
    return 0
  fi

  if [ "$mode" = "test" ]; then
    payload="$DEFAULT_TEST_PAYLOAD"
  else
    payload="$(read_payload "$payload_arg")"
  fi

  if ! [[ "$MAX_LEN" =~ ^[0-9]+$ ]]; then
    MAX_LEN=200
  fi

  TITLE="$(printf "%s" "$TITLE" | normalize_text | sanitize_for_osc)"
  MESSAGE="$(extract_message "$payload" | normalize_text | sanitize_for_osc)"
  MESSAGE="$(truncate_text "$MESSAGE" "$MAX_LEN")"

  emit_notification "$TITLE" "$MESSAGE"
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  main "$@"
fi
