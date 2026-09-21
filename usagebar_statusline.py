#!/usr/bin/env python3
"""Claude Code statusline: shows model + usage, and saves rate-limit
data for the UsageBar menu bar app."""
import json, sys, os, time

FEED = os.path.expanduser("~/Library/Application Support/UsageBar/claude_feed.json")

try:
    d = json.load(sys.stdin)
except Exception:
    d = {}

# find rate limit-ish objects anywhere in the payload
found = {}
def walk(o, path=""):
    if isinstance(o, dict):
        keys = set(o.keys())
        if keys & {"utilization", "used_percent", "used_percentage"}:
            found[path] = o
        for k, v in o.items():
            walk(v, (path + "." + k).strip("."))
    elif isinstance(o, list):
        for i, v in enumerate(o):
            walk(v, path)
walk(d)

session = weekly = s_reset = w_reset = None
def get_pct(o):
    v = o.get("utilization", o.get("used_percentage", o.get("used_percent")))
    try:
        return float(v)
    except (TypeError, ValueError):
        return None
def get_reset(o):
    v = o.get("resets_at", o.get("resetsAt"))
    if isinstance(v, str):
        try:
            from datetime import datetime
            return datetime.fromisoformat(v.replace("Z", "+00:00")).timestamp()
        except Exception:
            return None
    if isinstance(v, (int, float)) and v > 1e12:  # milliseconds
        return v / 1000.0
    return v

for path, o in found.items():
    p = path.lower()
    if "five_hour" in p or "fivehour" in p or "session" in p or "primary" in p:
        session, s_reset = get_pct(o), get_reset(o)
    elif ("seven_day" in p or "sevenday" in p or "week" in p or "secondary" in p) \
            and "opus" not in p:
        weekly, w_reset = get_pct(o), get_reset(o)

if session is not None or weekly is not None:
    try:
        os.makedirs(os.path.dirname(FEED), exist_ok=True)
        with open(FEED, "w") as f:
            json.dump({"ts": time.time(), "session": session, "weekly": weekly,
                       "session_reset": s_reset, "weekly_reset": w_reset}, f)
    except Exception:
        pass

# render statusline text
model = (d.get("model") or {}).get("display_name", "")
parts = [model] if model else []
if session is not None:
    parts.append("5h %.0f%%" % session)
if weekly is not None:
    parts.append("wk %.0f%%" % weekly)
cwd = (d.get("workspace") or {}).get("current_dir", "")
if cwd:
    parts.append(os.path.basename(cwd))
print(" | ".join(parts) if parts else "Claude")
