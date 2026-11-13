#!/usr/bin/env python3
"""Syntila VPS health monitor (runs every few minutes from a systemd timer).

Checks disk/inodes/memory, critical services, backend readiness (local and
public), TLS expiry, PostgreSQL connections, the nightly dump, backend restart
loops and failed units. Sends an alert when a check starts failing, a reminder
while it keeps failing, and a recovery notice. Optionally pings an external
heartbeat URL so an outside service notices when the whole VPS is down.

Configuration: /etc/syntila/monitor.env (see monitor.env.example).
State: /var/lib/syntila-monitor/state.json
"""
import json, os, shutil, socket, ssl, subprocess, sys, time, urllib.request
from datetime import datetime, timezone

CONFIG_FILE = os.environ.get("SYNTILA_MONITOR_CONFIG", "/etc/syntila/monitor.env")
STATE_FILE = os.environ.get("SYNTILA_MONITOR_STATE", "/var/lib/syntila-monitor/state.json")


def load_config():
    cfg = {
        "DISK_WARN_PCT": "80", "DISK_CRIT_PCT": "90", "MEM_MIN_AVAILABLE_PCT": "10",
        "SERVICES": "postgresql syntila-backend caddy",
        "LOCAL_READY_URL": "http://127.0.0.1:3000/health/ready",
        "PUBLIC_READY_URL": "https://api.syntila.app/health/ready",
        "TLS_HOST": "api.syntila.app", "TLS_MIN_DAYS": "14",
        "PG_CONN_WARN_PCT": "80", "DUMP_DIR": "/var/backups/syntila", "DUMP_MAX_AGE_HOURS": "26",
        "RESTART_BURST": "3", "REMIND_HOURS": "6",
        "ALERT_NTFY_URL": "", "ALERT_NTFY_TOKEN": "", "ALERT_SLACK_WEBHOOK": "",
        "ALERT_TELEGRAM_BOT_TOKEN": "", "ALERT_TELEGRAM_CHAT_ID": "", "HEARTBEAT_URL": "",
    }
    try:
        for line in open(CONFIG_FILE):
            line = line.strip()
            if line and not line.startswith("#") and "=" in line:
                k, v = line.split("=", 1)
                cfg[k.strip()] = v.strip().strip('"').strip("'")
    except FileNotFoundError:
        pass
    return cfg


def sh(*args, timeout=15):
    r = subprocess.run(args, capture_output=True, text=True, timeout=timeout)
    return r.returncode, r.stdout.strip()


def http_ok(url, timeout=8):
    try:
        with urllib.request.urlopen(url, timeout=timeout) as r:
            return r.status == 200, f"HTTP {r.status}"
    except Exception as e:  # noqa: BLE001
        return False, str(getattr(e, "code", "")) + " " + type(e).__name__


def checks(cfg, state):
    """Yields (key, ok, severity, message)."""
    warn, crit = int(cfg["DISK_WARN_PCT"]), int(cfg["DISK_CRIT_PCT"])
    seen = set()
    for line in open("/proc/mounts"):
        dev, mnt, fstype, options = line.split()[:4]
        if fstype not in ("ext4", "xfs", "btrfs", "vfat") or mnt in seen or mnt.startswith("/snap") or "ro" in options.split(","):
            continue
        seen.add(mnt)
        st = os.statvfs(mnt)
        if st.f_blocks == 0:
            continue
        used = 100 - st.f_bavail * 100 // st.f_blocks
        sev = "critical" if used >= crit else "warning"
        free_gb = st.f_bavail * st.f_frsize / 1e9
        yield f"disk:{mnt}", used < warn, sev, f"Disk {mnt} {used}% used ({free_gb:.1f} GB free)"
        if st.f_files:
            iused = 100 - st.f_favail * 100 // st.f_files
            yield f"inodes:{mnt}", iused < warn, sev, f"Inodes {mnt} {iused}% used"

    mem = {l.split(":")[0]: int(l.split()[1]) for l in open("/proc/meminfo")}
    avail = mem["MemAvailable"] * 100 // mem["MemTotal"]
    yield "memory", avail >= int(cfg["MEM_MIN_AVAILABLE_PCT"]), "warning", f"Memory available {avail}%"

    for svc in cfg["SERVICES"].split():
        code, out = sh("systemctl", "is-active", svc)
        yield f"service:{svc}", out == "active", "critical", f"Service {svc} is {out or 'unknown'}"

    code, failed = sh("systemctl", "list-units", "--state=failed", "--no-legend", "--plain")
    names = [l.split()[0] for l in failed.splitlines() if l.strip()]
    yield "failed-units", not names, "warning", "Failed units: " + (", ".join(names) or "none")

    # Restart loop: NRestarts growing quickly means the backend keeps crashing.
    code, n = sh("systemctl", "show", "syntila-backend", "-p", "NRestarts", "--value")
    if n.isdigit():
        history = [h for h in state.get("restarts", []) if time.time() - h[0] < 3600]
        history.append([time.time(), int(n)])
        state["restarts"] = history
        delta = history[-1][1] - history[0][1]
        yield "backend-restarts", delta < int(cfg["RESTART_BURST"]), "critical", f"syntila-backend restarted {delta} times in the last hour"

    ok, detail = http_ok(cfg["LOCAL_READY_URL"])
    yield "ready:local", ok, "critical", f"Backend readiness (local): {detail}"
    if cfg["PUBLIC_READY_URL"]:
        ok, detail = http_ok(cfg["PUBLIC_READY_URL"])
        yield "ready:public", ok, "critical", f"Backend readiness via {cfg['PUBLIC_READY_URL']}: {detail}"

    if cfg["TLS_HOST"]:
        try:
            ctx = ssl.create_default_context()
            with socket.create_connection((cfg["TLS_HOST"], 443), timeout=8) as s, ctx.wrap_socket(s, server_hostname=cfg["TLS_HOST"]) as t:
                exp = datetime.strptime(t.getpeercert()["notAfter"], "%b %d %H:%M:%S %Y %Z").replace(tzinfo=timezone.utc)
            days = (exp - datetime.now(timezone.utc)).days
            yield "tls", days >= int(cfg["TLS_MIN_DAYS"]), "warning", f"TLS certificate for {cfg['TLS_HOST']} expires in {days} days"
        except Exception as e:  # noqa: BLE001
            yield "tls", False, "warning", f"TLS check for {cfg['TLS_HOST']} failed: {type(e).__name__}"

    code, out = sh("sudo", "-u", "postgres", "psql", "-XAtqc",
                   "select count(*), current_setting('max_connections') from pg_stat_activity")
    if code == 0 and "|" in out:
        used, mx = map(int, out.split("|"))
        pct = used * 100 // mx
        yield "pg-connections", pct < int(cfg["PG_CONN_WARN_PCT"]), "warning", f"PostgreSQL connections {used}/{mx} ({pct}%)"
    else:
        yield "pg-connections", False, "critical", "PostgreSQL query failed"

    if cfg["DUMP_DIR"]:
        dumps = [os.path.join(cfg["DUMP_DIR"], f) for f in os.listdir(cfg["DUMP_DIR"]) if f.endswith(".dump")] if os.path.isdir(cfg["DUMP_DIR"]) else []
        age = (time.time() - max(map(os.path.getmtime, dumps))) / 3600 if dumps else None
        yield "dump", age is not None and age <= float(cfg["DUMP_MAX_AGE_HOURS"]), "warning", \
            "Nightly database dump: " + (f"latest is {age:.1f} h old" if age is not None else "none found")


def notify(cfg, title, body, priority="default"):
    host = socket.gethostname()
    text = f"[{host}] {title}\n{body}"
    sent = False
    try:
        if cfg["ALERT_NTFY_URL"]:
            req = urllib.request.Request(cfg["ALERT_NTFY_URL"], data=body.encode(), method="POST",
                                         headers={"Title": f"[{host}] {title}", "Priority": priority, "Tags": "rotating_light" if priority == "high" else "white_check_mark"})
            if cfg["ALERT_NTFY_TOKEN"]:
                req.add_header("Authorization", f"Bearer {cfg['ALERT_NTFY_TOKEN']}")
            urllib.request.urlopen(req, timeout=10); sent = True
        if cfg["ALERT_SLACK_WEBHOOK"]:
            urllib.request.urlopen(urllib.request.Request(cfg["ALERT_SLACK_WEBHOOK"], data=json.dumps({"text": text}).encode(),
                                                          headers={"Content-Type": "application/json"}), timeout=10); sent = True
        if cfg["ALERT_TELEGRAM_BOT_TOKEN"] and cfg["ALERT_TELEGRAM_CHAT_ID"]:
            url = f"https://api.telegram.org/bot{cfg['ALERT_TELEGRAM_BOT_TOKEN']}/sendMessage"
            urllib.request.urlopen(urllib.request.Request(url, data=json.dumps({"chat_id": cfg["ALERT_TELEGRAM_CHAT_ID"], "text": text}).encode(),
                                                          headers={"Content-Type": "application/json"}), timeout=10); sent = True
    except Exception as e:  # noqa: BLE001
        print(f"alert delivery failed: {e}", file=sys.stderr)
    print(("ALERT " if priority == "high" else "NOTICE ") + text.replace("\n", " | "))
    return sent


def main():
    cfg = load_config()
    if "--test-alert" in sys.argv:
        ok = notify(cfg, "Test alert", "Syntila monitor can reach you.", "high")
        sys.exit(0 if ok else 1)
    os.makedirs(os.path.dirname(STATE_FILE), exist_ok=True)
    try:
        state = json.load(open(STATE_FILE))
    except Exception:  # noqa: BLE001
        state = {}
    failing = state.setdefault("failing", {})
    remind = float(cfg["REMIND_HOURS"]) * 3600
    now = time.time()
    current = {}
    for key, ok, sev, msg in checks(cfg, state):
        current[key] = (ok, sev, msg)
    new_failures, reminders, recovered = [], [], []
    for key, (ok, sev, msg) in current.items():
        if not ok:
            prev = failing.get(key)
            if prev is None:
                failing[key] = {"since": now, "notified": now, "severity": sev}
                new_failures.append(f"{sev.upper()}: {msg}")
            elif now - prev["notified"] >= remind:
                prev["notified"] = now
                reminders.append(f"{sev.upper()} (since {datetime.fromtimestamp(prev['since'], timezone.utc):%Y-%m-%d %H:%M} UTC): {msg}")
        elif key in failing:
            del failing[key]
            recovered.append(msg)
    if new_failures or reminders:
        notify(cfg, "Syntila problem" if new_failures else "Syntila still failing", "\n".join(new_failures + reminders), "high")
    if recovered:
        notify(cfg, "Syntila recovered", "\n".join(recovered))
    with open(STATE_FILE + ".tmp", "w") as f:
        json.dump(state, f)
    os.replace(STATE_FILE + ".tmp", STATE_FILE)
    # Dead-man's switch: report only when every critical check passes.
    if cfg["HEARTBEAT_URL"]:
        critical_down = any(not ok and sev == "critical" for ok, sev, _ in current.values())
        try:
            urllib.request.urlopen(cfg["HEARTBEAT_URL"] + ("/fail" if critical_down else ""), timeout=10)
        except Exception as e:  # noqa: BLE001
            print(f"heartbeat failed: {e}", file=sys.stderr)
    if "--verbose" in sys.argv:
        for key, (ok, sev, msg) in sorted(current.items()):
            print(f"{'ok  ' if ok else 'FAIL'} {msg}")


if __name__ == "__main__":
    main()
