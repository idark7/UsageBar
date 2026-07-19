# UsageBar

macOS menu bar app showing Claude Code + Codex subscription usage next to the clock.

- Two-line status item: `C<claude%>` / `X<codex%>`, colored green (<60%), yellow (60-80%), red (>80%)
- Dropdown with animated progress bars, session + weekly windows, reset times
- Auto-refresh: 10s / 20s / 30s / 1h / off
- Toggle: show % used vs % remaining
- Claude data via Claude Code statusline feed (avoids the bugged /api/oauth/usage endpoint, see anthropics/claude-code#31637), with OAuth API fallback
- Codex data parsed from ~/.codex/sessions rollout logs

## Build

    swiftc -O -o UsageBar UsageBar.swift

## Install

    bash install_usagebar.sh   # builds .app + LaunchAgent (run at login)

Statusline hook (add to ~/.claude/settings.json):

    "statusLine": {"type": "command",
      "command": "/usr/bin/python3 \"~/Library/Application Support/UsageBar/usagebar_statusline.py\""}
