# Codex + Warp Integration

Lightweight bridge that sends Warp-native notifications when Codex finishes a turn.

## What this gives you

- Codex `notify` hook support
- Warp notification via OSC escape sequences
- Message preview from the latest Codex assistant response

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

## Test

Run:

```bash
"/Users/manar/Desktop/Projects/Codex - Warp Integration/scripts/test-notification.sh"
```

If you are in Warp, you should see a native notification.
