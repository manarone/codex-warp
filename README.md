# Codex + Warp

Lightweight Warp terminal integration for Codex notifications.

## Features

- Native Warp notifications via OSC sequences
- Message preview from the latest Codex assistant response
- Supports in-app notifications (`osc9`), desktop notifications (`osc777`), or both
- Better reliability when stdin is redirected (auto TTY discovery)

## Requirements

- [Warp terminal](https://warp.dev)
- Codex CLI with `notify` hook support
- `python3` (optional but recommended for richer JSON payload parsing)

## Installation

1. Make the script executable:

```bash
chmod +x "/path/to/codex-warp/codex-warp.sh"
```

1. Add this to `~/.codex/config.toml`:

```toml
notify = ["/path/to/codex-warp/codex-warp.sh"]
```

Recommended default (send both in-app and desktop styles):

```toml
notify = ["env", "CODEX_WARP_CHANNEL=both", "/path/to/codex-warp/codex-warp.sh"]
```

1. Restart Codex.

## Configuration

Use environment variables to customize behavior:

| Variable | Default | Description |
| --- | --- | --- |
| `CODEX_WARP_TITLE` | `Codex` | Notification title |
| `CODEX_WARP_MAX_LEN` | `200` | Max message preview length |
| `CODEX_WARP_CHANNEL` | `auto` | `auto`, `osc9`, `osc777`, or `both` |
| `CODEX_WARP_TTY` | unset | Explicit TTY override, e.g. `/dev/ttys033` |
| `CODEX_WARP_FORCE` | `0` | Force Warp detection for OSC 777 |
| `CODEX_WARP_DEBUG` | `0` | Debug logs to stderr |

Notes:
- `auto` currently maps to `osc9`.
- `CODEX_WARP_TTY` must point to a writable TTY character device.

## Test

Send a test notification:

```bash
"/path/to/codex-warp/codex-warp.sh" --test
```

Send explicit channel tests:

```bash
CODEX_WARP_CHANNEL=osc9 "/path/to/codex-warp/codex-warp.sh" --test
CODEX_WARP_CHANNEL=osc777 "/path/to/codex-warp/codex-warp.sh" --test
```

## How It Works

When Codex fires the `notify` hook, this script:

1. Reads hook payload JSON (or plain text fallback)
2. Extracts `last-assistant-message` (or a short fallback summary)
3. Normalizes, sanitizes, and truncates content for safe OSC output
4. Finds a writable TTY target (`/dev/tty`, tmux pane, SSH TTY, parent TTY)
5. Emits Warp-compatible notification escape sequences

## Troubleshooting

- If notifications stopped after moving files, verify `notify` path in `~/.codex/config.toml`.
- For desktop notifications, use `CODEX_WARP_CHANNEL=osc777` or `both`.
- Warp desktop notifications typically appear when Warp is not focused.
- If no TTY is found, set `CODEX_WARP_TTY` explicitly to your active Warp pane device.
- Use `CODEX_WARP_DEBUG=1` to see delivery logs.
