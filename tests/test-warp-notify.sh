#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../warp-notify-codex.sh
. "$ROOT_DIR/warp-notify-codex.sh"

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

test_truncate_short_limit() {
  assert_eq "abc" "$(truncate_text "abcdef" 3)" "truncate respects limit below ellipsis threshold"
  assert_eq "" "$(truncate_text "abcdef" 0)" "truncate returns empty for zero limit"
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
    "$ROOT_DIR/warp-notify-codex.sh" \
    '{"last-assistant-message":"Hello from perl fallback","input-messages":["ignored"]}')"

  rm -rf "$test_bin"

  assert_eq "Hello from perl fallback" "$output" "structured payload parses without python3"
}

test_json_input_fallback_summary() {
  assert_eq 'Completed: "Ship it"' "$(extract_message '{"input-messages":["Ship it"]}')" "first input summary is used when assistant text is missing"
}

main() {
  test_truncate_short_limit
  test_osc777_field_sanitization
  test_json_extraction_without_python
  test_json_input_fallback_summary
  printf 'All tests passed.\n'
}

main "$@"
