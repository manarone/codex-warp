# Codex + Warp Integration

Lightweight bridge that sends Warp-native notifications when Codex finishes a turn.

## What this gives you

- Codex `notify` hook support
- Warp notification via OSC escape sequences
- Message preview from the latest Codex assistant response
- Better hook reliability when stdin is redirected (auto TTY discovery)

## Files

- `scripts/warp-notify-codex.sh`: main notify hook command (used by Codex)
- `scripts/test-notification.sh`: sends a local test notification

## Setup

1. Make scripts executable:

```bash
chmod +x "/Users/manar/Desktop/Projects/Codex - Warp Integration/scripts/warp-notify-codex.sh"
chmod +x "/Users/manar/Desktop/Projects/Codex - Warp Integration/scripts/test-notification.sh"
```

2. Add this to `~/.codex/config.toml`:

```toml
notify = ["/Users/manar/Desktop/Projects/Codex - Warp Integration/scripts/warp-notify-codex.sh"]
```

3. Optional TUI notifications (for approvals, etc.):

```toml
[tui]
notifications = ["approval-requested"]
notification_method = "osc9"
```

4. Restart Codex.

## Optional environment variables

- `CODEX_WARP_TITLE`: notification title (default: `Codex`)
- `CODEX_WARP_MAX_LEN`: max preview length (default: `200`)
- `CODEX_WARP_FORCE=1`: force Warp-native OSC 777 notifications
- `CODEX_WARP_TTY=/dev/ttysXXX`: explicit terminal device override (must be a TTY device path)
- `CODEX_WARP_DEBUG=1`: debug logs to stderr
- `CODEX_WARP_CHANNEL`: `auto` (default), `osc9`, `osc777`, or `both`

## Test

Run:

```bash
"/Users/manar/Desktop/Projects/Codex - Warp Integration/scripts/test-notification.sh"
```

If you are in Warp, you should see a notification.

## Troubleshooting

- `CODEX_WARP_CHANNEL=auto` defaults to `osc9` (Claude-like in-app toast behavior in Warp).
- Use `CODEX_WARP_CHANNEL=osc777` for Warp desktop notifications.
- Use `CODEX_WARP_CHANNEL=both` to send both in-app and desktop styles.
- Warp desktop notifications (`osc777`) appear when Warp is not the active/focused app.
- If notifications do not appear from the Codex hook, set `CODEX_WARP_FORCE=1`.
- If your runtime has no controlling TTY, set `CODEX_WARP_TTY` to your Warp pane device (for example `/dev/ttys009`).
- `CODEX_WARP_TTY` intentionally rejects non-TTY files for safety.
