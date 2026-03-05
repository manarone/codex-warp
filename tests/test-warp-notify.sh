#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../codex-warp.sh
. "$ROOT_DIR/codex-warp.sh"

assert_eq() {
  local expected="$1"
  local actual="$2"
  local label="$3"

  if [ "$expected" != "$actual" ]; then
    printf 'FAIL: %s\nexpected: %q\nactual:   %q\n' "$label" "$expected" "$actual" >&2
    exit 1
  fi

  printf 'PASS: %s\n' "$label"
}

assert_contains() {
  local needle="$1"
  local haystack="$2"
  local label="$3"

  if [[ "$haystack" != *"$needle"* ]]; then
    printf 'FAIL: %s\nmissing: %q\nfull output: %s\n' "$label" "$needle" "$haystack" >&2
    exit 1
  fi

  printf 'PASS: %s\n' "$label"
}

test_truncate_short_limit() {
  assert_eq "abc" "$(truncate_text "abcdef" 3)" "truncate respects limit below ellipsis threshold"
  assert_eq "" "$(truncate_text "abcdef" 0)" "truncate returns empty for zero limit"
}

test_auto_channel_prefers_both_in_warp() {
  local original_term_program="${TERM_PROGRAM-}"
  local original_warp_local="${WARP_IS_LOCAL_SHELL_SESSION-}"

  TERM_PROGRAM="WarpTerminal"
  WARP_IS_LOCAL_SHELL_SESSION=1
  assert_eq "both" "$(resolve_notification_channel "auto")" "auto channel upgrades to both inside Warp"

  if [ -n "$original_term_program" ]; then
    TERM_PROGRAM="$original_term_program"
  else
    unset TERM_PROGRAM
  fi

  if [ -n "$original_warp_local" ]; then
    WARP_IS_LOCAL_SHELL_SESSION="$original_warp_local"
  else
    unset WARP_IS_LOCAL_SHELL_SESSION
  fi
}

test_auto_channel_falls_back_to_osc9_outside_warp() {
  local original_term_program="${TERM_PROGRAM-}"
  local original_warp_local="${WARP_IS_LOCAL_SHELL_SESSION-}"

  unset TERM_PROGRAM
  unset WARP_IS_LOCAL_SHELL_SESSION
  assert_eq "osc9" "$(resolve_notification_channel "auto")" "auto channel falls back to osc9 outside Warp"

  if [ -n "$original_term_program" ]; then
    TERM_PROGRAM="$original_term_program"
  fi

  if [ -n "$original_warp_local" ]; then
    WARP_IS_LOCAL_SHELL_SESSION="$original_warp_local"
  fi
}

test_osc777_field_sanitization() {
  assert_eq "semi,colon title" "$(printf "%s" "semi;colon title" | sanitize_for_osc777_field)" "osc777 semicolons are normalized"
}

test_json_extraction_without_python() {
  local test_bin=""
  local output=""

  test_bin="$(mktemp -d)"

  ln -s /bin/bash "$test_bin/bash"
  ln -s /usr/bin/env "$test_bin/env"
  ln -s /usr/bin/tr "$test_bin/tr"
  ln -s /usr/bin/sed "$test_bin/sed"
  ln -s /bin/ps "$test_bin/ps"
  ln -s /usr/bin/perl "$test_bin/perl"

  output="$(PATH="$test_bin" bash -c '. "$1"; extract_message "$2"' _ \
    "$ROOT_DIR/codex-warp.sh" \
    '{"last-assistant-message":"Hello from perl fallback","input-messages":["ignored"]}')"

  rm -rf "$test_bin"

  assert_eq "Hello from perl fallback" "$output" "structured payload parses without python3"
}

test_json_input_fallback_summary() {
  assert_eq 'Completed: "Ship it"' "$(extract_message '{"input-messages":["Ship it"]}')" "first input summary is used when assistant text is missing"
}

test_notification_fields_include_prompt_and_event_title() {
  local fields=""
  local title=""
  local message=""
  local IFS=$'\036'

  fields="$(extract_notification_fields "Codex" '{"type":"agent-turn-complete","input-messages":["Ship it"],"last-assistant-message":"Done and pushed."}')"
  read -r title message <<<"$fields"

  assert_eq "Codex finished" "$title" "completion title is event-aware"
  assert_eq '"Ship it" -> Done and pushed.' "$message" "message includes prompt and response"
}

test_notification_fields_can_request_input() {
  local fields=""
  local title=""
  local message=""
  local IFS=$'\036'

  fields="$(extract_notification_fields "Codex" '{"type":"input-request","input-messages":["Approve deploy"]}')"
  read -r title message <<<"$fields"

  assert_eq "Codex needs input" "$title" "input event title is specific"
  assert_eq 'Input needed for "Approve deploy"' "$message" "input event body is specific"
}

test_compact_notification_body_splits_budget() {
  local body=""

  body="$(compact_notification_body '"please audit this codebase is it good to ship?" -> Great. The richer title/body format plus the desktop time token seems to have fixed the repeat-notification problem.' 72)"
  assert_eq '"please audit this co... -> Great. The richer title/body format plus ...' "$body" "compact body preserves both prompt and response"
}

test_should_notify_payload_filters_unknown_events() {
  if command -v python3 >/dev/null 2>&1; then
    if should_notify_payload '{"type":"telemetry-heartbeat"}'; then
      printf 'FAIL: unknown event payload should be skipped\n' >&2
      exit 1
    fi

    if ! should_notify_payload '{"type":"agent-turn-complete"}'; then
      printf 'FAIL: agent turn complete should notify\n' >&2
      exit 1
    fi

    if should_notify_payload '{"type":"agent-turn-complete","source":"subagent"}'; then
      printf 'FAIL: subagent-marked payload should be skipped\n' >&2
      exit 1
    fi
  fi

  printf 'PASS: notification payload filter behaves as expected\n'
}

test_read_payload_from_stdin() {
  local output=""

  output="$(printf '%s' '{"last-assistant-message":"stdin payload"}' | bash -c '. "$1"; read_payload ""' _ "$ROOT_DIR/codex-warp.sh")"
  assert_eq '{"last-assistant-message":"stdin payload"}' "$output" "payload can be read from stdin"
}

test_doctor_reports_config_and_effective_channel() {
  local temp_home=""
  local output=""

  temp_home="$(mktemp -d)"
  mkdir -p "$temp_home/.codex"
  printf 'notify = ["env", "CODEX_WARP_CHANNEL=both", "%s"]\n' "$ROOT_DIR/codex-warp.sh" > "$temp_home/.codex/config.toml"

  output="$(HOME="$temp_home" TERM_PROGRAM=WarpTerminal WARP_IS_LOCAL_SHELL_SESSION=1 CODEX_WARP_TTY=/dev/null CODEX_WARP_CHANNEL=auto \
    bash -c '. "$1"; run_doctor 0' _ "$ROOT_DIR/codex-warp.sh")"

  rm -rf "$temp_home"

  assert_contains 'effective_channel: both' "$output" "doctor reports effective auto channel"
  assert_contains 'config_status: exact' "$output" "doctor confirms exact config reference"
  assert_contains 'doctor_action: rerun with --doctor --send-test to send in-app and desktop samples.' "$output" "doctor suggests follow-up test"
}

main() {
  test_truncate_short_limit
  test_auto_channel_prefers_both_in_warp
  test_auto_channel_falls_back_to_osc9_outside_warp
  test_osc777_field_sanitization
  test_json_extraction_without_python
  test_json_input_fallback_summary
  test_notification_fields_include_prompt_and_event_title
  test_notification_fields_can_request_input
  test_compact_notification_body_splits_budget
  test_should_notify_payload_filters_unknown_events
  test_read_payload_from_stdin
  test_doctor_reports_config_and_effective_channel
  printf 'All tests passed.\n'
}

main "$@"
