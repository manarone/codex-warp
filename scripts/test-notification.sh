#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

PAYLOAD='{
  "type":"agent-turn-complete",
  "thread-id":"test-thread",
  "turn-id":"1",
  "cwd":"'"$(pwd)"'",
  "input-messages":["Send a Warp notification"],
  "last-assistant-message":"Codex + Warp notification bridge is working."
}'

"$SCRIPT_DIR/warp-notify-codex.sh" "$PAYLOAD"
printf "Sent test notification.\n"
