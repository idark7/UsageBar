#!/usr/bin/env python3
"""Fetch Claude Code + Codex usage. Prints JSON:
{"claude":{"session":p,"weekly":p,"session_reset":ts,"weekly_reset":ts,"err":..},
 "codex":{"session":p,"weekly":p,"session_reset":ts,"weekly_reset":ts,"err":..}}
Percentages are USED percent (0-100)."""
import json, subprocess, time, os, glob, re, urllib.request, urllib.error, sys

KC_SERVICE = "Claude Code-credentials"
CLIENT_ID = "9d1c250a-e61b-44d9-88ed-5944d1962f5e"


KC_SERVICE_USED = KC_SERVICE


def _kc_get(service):
    out = subprocess.run(["security", "find-generic-password", "-s", service, "-w"],
                         capture_output=True, text=True, timeout=15)
    if out.returncode != 0:
        return None
    try:
        return json.loads(out.stdout.strip())
    except Exception:
        return None


def _has_token(d):
    o = (d or {}).get("claudeAiOauth") or {}
    return bool(o.get("accessToken") or o.get("refreshToken"))


def kc_read():
    """Newer Claude Code stores creds under 'Claude Code-credentials-<hash>'
    (and may leave the legacy entry with blank tokens). Pick the first entry
    that actually holds a token; fall back to ~/.claude/.credentials.json."""
    global KC_SERVICE_USED
    d = _kc_get(KC_SERVICE)
    if _has_token(d):
        return d
    try:
        dump = subprocess.run(["security", "dump-keychain"], capture_output=True,
                              text=True, timeout=20).stdout
        names = sorted(set(re.findall(r'"svce"<blob>="(Claude Code-credentials[^"]*)"', dump)))
    except Exception:
        names = []
    best, best_exp = None, -1
    for n in names:
        if n == KC_SERVICE:
            continue
        e = _kc_get(n)
        if _has_token(e):
            exp = (e["claudeAiOauth"].get("expiresAt") or 0)
            if exp > best_exp:
                best, best_exp, KC_SERVICE_USED = e, exp, n
    if best:
        return best
    try:
        with open(os.path.expanduser("~/.claude/.credentials.json")) as f:
            e = json.load(f)
        if _has_token(e):
            KC_SERVICE_USED = None
            return e
    except Exception:
        pass
    return d


def kc_write(full):
    if KC_SERVICE_USED is None:
        return  # creds came from the json file; don't touch the keychain
    data = json.dumps(full)
    subprocess.run(["security", "add-generic-password", "-U", "-s", KC_SERVICE_USED,
                    "-a", os.environ.get("USER", ""), "-w", data],
                   capture_output=True, text=True, timeout=15)


def http_json(url, method="GET", body=None, headers=None):
    req = urllib.request.Request(url, method=method,
                                 data=json.dumps(body).encode() if body else None)
    req.add_header("Content-Type", "application/json")
    req.add_header("User-Agent", "claude-cli/2.0.0 (external, cli)")
    for k, v in (headers or {}).items():
        req.add_header(k, v)
    with urllib.request.urlopen(req, timeout=15) as r:
        return json.loads(r.read().decode())


BACKOFF = os.path.expanduser("~/Library/Application Support/UsageBar/.refresh_backoff")


def to_epoch(v):
    """resets_at may be epoch seconds, epoch ms, or an ISO-8601 string."""
    if isinstance(v, str):
        try:
            from datetime import datetime
            return datetime.fromisoformat(v.replace("Z", "+00:00")).timestamp()
        except Exception:
            return None
    if isinstance(v, (int, float)) and v > 1e12:
        return v / 1000.0
    return v


def refresh_claude(full):
    # don't attempt refresh more than once per 10 min
    try:
        if time.time() - os.path.getmtime(BACKOFF) < 600:
            raise RuntimeError("refresh backoff")
    except OSError:
        pass
    open(BACKOFF, "w").close()
    oauth = full["claudeAiOauth"]
    d = http_json("https://console.anthropic.com/v1/oauth/token", "POST",
                  {"grant_type": "refresh_token",
                   "refresh_token": oauth["refreshToken"],
                   "client_id": CLIENT_ID})
    oauth["accessToken"] = d["access_token"]
    if d.get("refresh_token"):
        oauth["refreshToken"] = d["refresh_token"]
    oauth["expiresAt"] = int(time.time() * 1000) + d.get("expires_in", 3600) * 1000
    kc_write(full)
    return oauth["accessToken"]


CACHE = os.path.expanduser("~/Library/Application Support/UsageBar/cache.json")


def load_cache():
    try:
        with open(CACHE) as f:
            return json.load(f)
    except Exception:
        return {}


def save_cache(c):
    try:
        with open(CACHE, "w") as f:
            json.dump(c, f)
    except Exception:
        pass


FEED = os.path.expanduser("~/Library/Application Support/UsageBar/claude_feed.json")


def claude_feed():
    """Rate-limit data captured by the Claude Code statusline hook."""
    try:
        with open(FEED) as f:
            d = json.load(f)
        # trust the feed for up to 24h; windows that have since reset are zeroed below
        if time.time() - d.get("ts", 0) < 24 * 3600 and d.get("session") is not None:
            now = time.time()
            r = {"session": d.get("session"), "weekly": d.get("weekly"),
                 "session_reset": d.get("session_reset"),
                 "weekly_reset": d.get("weekly_reset"), "err": None,
                 "ts": d.get("ts", 0)}
            if r["session_reset"] and r["session_reset"] < now:
                r["session"], r["session_reset"] = 0.0, None
            if r["weekly_reset"] and r["weekly_reset"] < now:
                r["weekly"], r["weekly_reset"] = 0.0, None
            return r
    except Exception:
        pass
    return None


DESKTOP_HISTORY = os.path.expanduser(
    "~/Library/Application Support/Claude/plan-usage-history.json")


def claude_desktop():
    """The Claude desktop app samples plan usage every ~15 min into
    plan-usage-history.json: {"samples":[{"t": ms, "u": {"fh": %, "sd": %}}]}.
    No reset times, but it works without a terminal session or OAuth token."""
    try:
        with open(DESKTOP_HISTORY) as f:
            samples = json.load(f).get("samples") or []
        last = max(samples, key=lambda x: x.get("t", 0))
        ts = last["t"] / 1000.0
        if time.time() - ts > 24 * 3600:
            return None
        u = last.get("u") or {}
        if u.get("fh") is None:
            return None
        return {"session": float(u["fh"]), "weekly": float(u["sd"]) if u.get("sd") is not None else None,
                "session_reset": None, "weekly_reset": None, "err": None, "ts": ts}
    except Exception:
        return None


def claude_usage():
    feed = claude_feed()
    desk = claude_desktop()
    # prefer whichever local source was written most recently
    best = max([x for x in (feed, desk) if x], key=lambda x: x.get("ts", 0), default=None)
    if best:
        best.pop("ts", None)
        return best
    cache = load_cache()
    now = time.time()
    cached = cache.get("claude")
    if cached and now - cache.get("ts", 0) > 24 * 3600:
        cached = None  # a day-old reading is worse than "no data"
    # serve cache: fresh (<5 min), or in 429 cooldown
    if cached:
        if now - cache.get("ts", 0) < 300:
            return cached
        if now < cache.get("cooldown_until", 0):
            cached = dict(cached)
            cached["err"] = "rate-limited, retrying soon"
            return cached
    r = claude_usage_fetch()
    if r.get("err") == "no creds":
        r["err"] = "not signed in — usage comes from the Claude Code status line"
        return r
    if r.get("err") and "429" in r["err"]:
        cache["cooldown_until"] = now + 1800
        save_cache(cache)
        if cached:
            cached = dict(cached)
            cached["err"] = "rate-limited, retrying soon"
            return cached
        r["err"] = "rate-limited, retrying soon"
        return r
    if r.get("session") is not None:
        cache["claude"] = r
        cache["ts"] = now
        cache["cooldown_until"] = 0
        save_cache(cache)
    elif cached:
        cached = dict(cached)
        cached["err"] = r.get("err")
        return cached
    return r


def claude_usage_fetch():
    r = {"session": None, "weekly": None, "session_reset": None,
         "weekly_reset": None, "err": None}
    try:
        full = kc_read()
        if not _has_token(full):
            r["err"] = "no creds"
            return r
        oauth = full["claudeAiOauth"]
        tok = oauth.get("accessToken")
        if oauth.get("expiresAt", 0) < time.time() * 1000 + 60000:
            try:
                tok = refresh_claude(full)
            except Exception:
                pass  # try existing token anyway
        hdrs = {"Authorization": "Bearer " + tok,
                "anthropic-beta": "oauth-2025-04-20"}
        try:
            d = http_json("https://api.anthropic.com/api/oauth/usage", headers=hdrs)
        except urllib.error.HTTPError as e:
            if e.code in (401, 403):
                try:
                    tok = refresh_claude(full)
                except Exception:
                    r["err"] = "Claude token expired — open a Claude Code session to update"
                    return r
                hdrs["Authorization"] = "Bearer " + tok
                d = http_json("https://api.anthropic.com/api/oauth/usage", headers=hdrs)
            else:
                raise

        def pick(obj):
            if not isinstance(obj, dict):
                return None, None
            u = obj.get("utilization")
            return (float(u) if u is not None else None), to_epoch(obj.get("resets_at"))

        # search likely keys
        flat = {}
        def walk(o, path=""):
            if isinstance(o, dict):
                if "utilization" in o:
                    flat[path] = o
                for k, v in o.items():
                    walk(v, (path + "." + k).strip("."))
        walk(d)
        for path, obj in flat.items():
            p = path.lower()
            u, rst = pick(obj)
            if "five_hour" in p or "session" in p:
                r["session"], r["session_reset"] = u, rst
            elif "seven_day" in p and "opus" not in p or "week" in p:
                r["weekly"], r["weekly_reset"] = u, rst
        if r["session"] is None and flat:
            u, rst = pick(list(flat.values())[0])
            r["session"], r["session_reset"] = u, rst
    except Exception as e:
        r["err"] = str(e)[:120]
    return r


def codex_usage():
    r = {"session": None, "weekly": None, "session_reset": None,
         "weekly_reset": None, "err": None}
    try:
        files = glob.glob(os.path.expanduser("~/.codex/sessions/**/*.jsonl"),
                         recursive=True)
        if not files:
            r["err"] = "no sessions"
            return r
        files.sort(key=os.path.getmtime, reverse=True)
        for f in files[:10]:
            found = None
            try:
                with open(f, "r", errors="ignore") as fh:
                    for line in fh:
                        if '"rate_limits"' not in line:
                            continue
                        try:
                            obj = json.loads(line)
                        except Exception:
                            continue
                        def find_rl(o):
                            if isinstance(o, dict):
                                if "rate_limits" in o and isinstance(o["rate_limits"], dict):
                                    return o["rate_limits"]
                                for v in o.values():
                                    x = find_rl(v)
                                    if x:
                                        return x
                            return None
                        rl = find_rl(obj)
                        if rl and isinstance(rl.get("primary"), dict) \
                                and rl["primary"].get("used_percent") is not None:
                            if found and not isinstance(rl.get("secondary"), dict):
                                rl = dict(rl)
                                rl["secondary"] = found.get("secondary")
                            found = rl
            except Exception:
                continue
            if found:
                p, s = found.get("primary") or {}, found.get("secondary") or {}
                r["session"] = p.get("used_percent")
                r["session_reset"] = p.get("resets_at")
                r["weekly"] = s.get("used_percent")
                r["weekly_reset"] = s.get("resets_at")
                # if window already reset, usage is effectively 0 now
                now = time.time()
                if r["session_reset"] and r["session_reset"] < now:
                    r["session"], r["session_reset"] = 0.0, None
                if r["weekly_reset"] and r["weekly_reset"] < now:
                    r["weekly"], r["weekly_reset"] = 0.0, None
                return r
        r["err"] = "no rate data"
    except Exception as e:
        r["err"] = str(e)[:120]
    return r


print(json.dumps({"claude": claude_usage(), "codex": codex_usage()}))
