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
MAX_LEN="${CODEX_WARP_MAX_LEN:-140}"
FORCE_WARP="${CODEX_WARP_FORCE:-0}"
TTY_OVERRIDE="${CODEX_WARP_TTY:-}"
DEBUG="${CODEX_WARP_DEBUG:-0}"
CHANNEL="${CODEX_WARP_CHANNEL:-auto}"
DESKTOP_TOKEN="${CODEX_WARP_DESKTOP_TOKEN:-1}"

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

compact_notification_body() {
  local body="$1"
  local limit="$2"
  local separator=' -> '
  local left=""
  local right=""
  local separator_len=4
  local prompt_budget=0
  local response_budget=0

  if [ "${#body}" -le "$limit" ]; then
    printf "%s" "$body"
    return 0
  fi

  if [[ "$body" != *"$separator"* ]]; then
    truncate_text "$body" "$limit"
    return 0
  fi

  left="${body%%"$separator"*}"
  right="${body#*"$separator"}"

  if [ "$limit" -le 24 ]; then
    truncate_text "$body" "$limit"
    return 0
  fi

  prompt_budget=$((limit / 3))
  if [ "$prompt_budget" -lt 18 ]; then
    prompt_budget=18
  fi
  if [ "$prompt_budget" -gt 40 ]; then
    prompt_budget=40
  fi

  response_budget=$((limit - separator_len - prompt_budget))
  if [ "$response_budget" -lt 18 ]; then
    response_budget=18
    prompt_budget=$((limit - separator_len - response_budget))
  fi

  if [ "$prompt_budget" -lt 8 ]; then
    truncate_text "$body" "$limit"
    return 0
  fi

  printf "%s%s%s" \
    "$(truncate_text "$left" "$prompt_budget")" \
    "$separator" \
    "$(truncate_text "$right" "$response_budget")"
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

extract_notification_fields_with_python() {
  local title_base="$1"
  local payload="$2"
  python3 - "$title_base" "$payload" <<'PY'
import json
import re
import sys

title_base = sys.argv[1]
raw = sys.argv[2]
SEP = "\x1e"

def normalize(value):
    return re.sub(r"\s+", " ", str(value or "")).strip()

def title_for(event_type):
    lower = normalize(event_type).lower()
    if any(token in lower for token in ("error", "fail")):
        suffix = "error"
    elif any(token in lower for token in ("input", "approval", "auth", "confirm")):
        suffix = "needs input"
    elif any(token in lower for token in ("start", "session-start")):
        suffix = "started"
    elif any(token in lower for token in ("complete", "stop", "finish", "done")):
        suffix = "finished"
    else:
        suffix = "update"
    return f"{title_base} {suffix}"

def body_for(event_type, prompt, assistant):
    title = title_for(event_type)
    if prompt and assistant:
        if assistant == prompt:
            return assistant
        return f'"{prompt}" -> {assistant}'
    if assistant:
        return assistant
    if prompt:
        if title.endswith("needs input"):
            return f'Input needed for "{prompt}"'
        if title.endswith("started"):
            return f'Started: "{prompt}"'
        return f'Completed: "{prompt}"'
    if title.endswith("needs input"):
        return "Codex needs your input."
    if title.endswith("started"):
        return "Codex session started."
    if title.endswith("error"):
        return "Codex reported an error."
    if title.endswith("finished"):
        return "Agent turn complete"
    return "Agent update available"

try:
    data = json.loads(raw)
except Exception:
    text = normalize(raw) or "Agent turn complete"
    print(title_for(""), end=SEP)
    print(text, end="")
    raise SystemExit(0)

if not isinstance(data, dict):
    text = normalize(raw) or "Agent turn complete"
    print(title_for(""), end=SEP)
    print(text, end="")
    raise SystemExit(0)

event_type = data.get("type") or ""
assistant = normalize(data.get("last-assistant-message") or "")
inputs = data.get("input-messages") or []
prompt = ""
if isinstance(inputs, list) and inputs:
    prompt = normalize(inputs[0])

print(title_for(event_type), end=SEP)
print(body_for(event_type, prompt, assistant), end="")
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

extract_notification_fields_with_perl() {
  local title_base="$1"
  local payload="$2"
  perl -MJSON::PP -e '
    my ($title_base, $raw) = @ARGV;
    my $sep = "\x1e";

    sub normalize {
      my ($value) = @_;
      $value = defined $value ? "$value" : "";
      $value =~ s/\s+/ /g;
      $value =~ s/^ +| +$//g;
      return $value;
    }

    sub title_for {
      my ($event_type) = @_;
      my $lower = lc normalize($event_type);
      my $suffix = "update";
      if ($lower =~ /(error|fail)/) {
        $suffix = "error";
      } elsif ($lower =~ /(input|approval|auth|confirm)/) {
        $suffix = "needs input";
      } elsif ($lower =~ /(start|session-start)/) {
        $suffix = "started";
      } elsif ($lower =~ /(complete|stop|finish|done)/) {
        $suffix = "finished";
      }
      return "$title_base $suffix";
    }

    sub body_for {
      my ($event_type, $prompt, $assistant) = @_;
      my $title = title_for($event_type);

      if (length($prompt) && length($assistant)) {
        return $assistant if $assistant eq $prompt;
        return qq{"$prompt" -> $assistant};
      }
      return $assistant if length($assistant);
      if (length($prompt)) {
        return qq{Input needed for "$prompt"} if $title =~ /needs input$/;
        return qq{Started: "$prompt"} if $title =~ /started$/;
        return qq{Completed: "$prompt"};
      }
      return "Codex needs your input." if $title =~ /needs input$/;
      return "Codex session started." if $title =~ /started$/;
      return "Codex reported an error." if $title =~ /error$/;
      return "Agent turn complete" if $title =~ /finished$/;
      return "Agent update available";
    }

    my $data = eval { JSON::PP::decode_json($raw) };
    if ($@ || ref($data) ne "HASH") {
      my $text = normalize($raw);
      $text = "Agent turn complete" unless length($text);
      print title_for(""), $sep, $text;
      exit 0;
    }

    my $event_type = $data->{"type"} // "";
    my $assistant = normalize($data->{"last-assistant-message"} // "");
    my $inputs = $data->{"input-messages"};
    my $prompt = "";
    if (ref($inputs) eq "ARRAY" && @{$inputs}) {
      $prompt = normalize($inputs->[0]);
    }

    print title_for($event_type), $sep, body_for($event_type, $prompt, $assistant);
  ' "$title_base" "$payload"
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

default_title_for_event() {
  local title_base="$1"
  local event_type="${2:-}"
  local lower_type=""
  local suffix="update"

  lower_type="$(printf "%s" "$event_type" | tr '[:upper:]' '[:lower:]')"
  if printf "%s" "$lower_type" | grep -Eq 'error|fail'; then
    suffix="error"
  elif printf "%s" "$lower_type" | grep -Eq 'input|approval|auth|confirm'; then
    suffix="needs input"
  elif printf "%s" "$lower_type" | grep -Eq 'start|session-start'; then
    suffix="started"
  elif printf "%s" "$lower_type" | grep -Eq 'complete|stop|finish|done'; then
    suffix="finished"
  fi

  printf "%s %s" "$title_base" "$suffix"
}

should_notify_payload_with_python() {
  local payload="$1"
  python3 - "$payload" <<'PY'
import json
import sys

raw = sys.argv[1]

try:
    data = json.loads(raw)
except Exception:
    print("notify")
    raise SystemExit(0)

if not isinstance(data, dict):
    print("notify")
    raise SystemExit(0)

event_type = str(data.get("type") or "").strip().lower()
source = str(data.get("source") or data.get("origin") or "").strip().lower()
kind = str(data.get("agent-kind") or data.get("agent_kind") or "").strip().lower()

if source in {"subagent", "sub-agent"} or kind in {"subagent", "sub-agent"}:
    print("skip")
elif event_type.startswith("agent-turn-") or any(token in event_type for token in ("input", "approval", "auth", "confirm", "error", "fail", "start", "stop", "finish", "done")):
    print("notify")
else:
    print("skip")
PY
}

should_notify_payload() {
  local payload="$1"
  local verdict=""

  if [ -z "$payload" ]; then
    return 0
  fi

  if command -v python3 >/dev/null 2>&1; then
    verdict="$(should_notify_payload_with_python "$payload")"
    if [ "$verdict" = "notify" ]; then
      return 0
    fi
    return 1
  fi

  return 0
}

extract_notification_fields() {
  local title_base="$1"
  local payload="$2"
  local message=""

  if [ -z "$payload" ]; then
    printf '%s\036%s' "$(default_title_for_event "$title_base" "agent-turn-complete")" "Agent turn complete"
    return 0
  fi

  if command -v python3 >/dev/null 2>&1; then
    extract_notification_fields_with_python "$title_base" "$payload"
    return 0
  fi

  if command -v perl >/dev/null 2>&1; then
    extract_notification_fields_with_perl "$title_base" "$payload"
    return 0
  fi

  message="$(extract_message "$payload")"
  printf '%s\036%s' "$(default_title_for_event "$title_base" "")" "$message"
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
  local timestamp_suffix=""

  if [ -z "$tty_target" ] && ! tty_target="$(resolve_tty_target)"; then
    log_debug "No writable terminal target found; skipping notification."
    return 0
  fi

  selected_channel="$(resolve_notification_channel "$selected_channel")"

  osc777_title="$(printf "%s" "$title" | sanitize_for_osc777_field)"
  osc777_body="$(printf "%s" "$body" | sanitize_for_osc777_field)"
  if [ "$DESKTOP_TOKEN" = "1" ]; then
    timestamp_suffix="$(date '+ [%H:%M:%S]' 2>/dev/null || true)"
    osc777_title="${osc777_title}${timestamp_suffix}"
  fi

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
    MAX_LEN=140
  fi

  if ! should_notify_payload "$payload"; then
    log_debug "Skipping payload because it does not match top-level notification events."
    return 0
  fi

  local normalized_title=""
  local extracted_fields=""
  local MESSAGE=""
  local IFS=$'\036'

  normalized_title="$(printf "%s" "$TITLE" | normalize_text | sanitize_for_osc)"
  extracted_fields="$(extract_notification_fields "$normalized_title" "$payload")"
  read -r TITLE MESSAGE <<<"$extracted_fields"
  TITLE="$(printf "%s" "$TITLE" | normalize_text | sanitize_for_osc)"
  MESSAGE="$(printf "%s" "$MESSAGE" | normalize_text | sanitize_for_osc)"
  MESSAGE="$(compact_notification_body "$MESSAGE" "$MAX_LEN")"

  emit_notification "$TITLE" "$MESSAGE"
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  main "$@"
fi
