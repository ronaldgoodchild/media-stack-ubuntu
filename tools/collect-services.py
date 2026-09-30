#!/usr/bin/env python3
"""Resolves the "services" section of dashboard/stats.json: each container's
up/starting/down status, its live full container ID (for the Portainer
deep-link), and — for apps whose API we know how to read — a one-line live
stat ("3 queued - 5 missing", "idle", "2 streaming", etc). Also fires an
ntfy.sh push notification on any actual down<->up transition since the last
run, if NTFY_TOPIC is set in .env (never on every poll, never on the first
run after install — see fire_alerts()).

Called by update-stats.sh every 30s via `docker compose ps`/`docker inspect`
and each app's own localhost API — not meant to be run by hand, though
harmless to. Prints the services object as one line of JSON to stdout.
"""
import json
import os
import re
import subprocess
import sys
import urllib.error
import urllib.request

INSTALL_ROOT = sys.argv[1] if len(sys.argv) > 1 else "/opt/mediastack"
APPDATA = "/mnt/media/AppData"

ARR_APPS = {
    "sonarr":   {"port": 8989, "api_ver": "v3"},
    "radarr":   {"port": 7878, "api_ver": "v3"},
    "lidarr":   {"port": 8686, "api_ver": "v1"},
    "whisparr": {"port": 6969, "api_ver": "v3"},
    "readarr":  {"port": 8787, "api_ver": "v1"},
}


def api(url, headers=None, timeout=5):
    req = urllib.request.Request(url, headers=headers or {})
    try:
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            return json.loads(resp.read())
    except (urllib.error.URLError, urllib.error.HTTPError, TimeoutError, ValueError, OSError):
        return None


def read_api_key(app):
    try:
        with open(f"{APPDATA}/{app}/config.xml") as f:
            m = re.search(r"<ApiKey>([^<]+)</ApiKey>", f.read())
            return m.group(1) if m else None
    except OSError:
        return None


def read_env(key):
    try:
        with open(f"{INSTALL_ROOT}/.env") as f:
            for line in f:
                if line.startswith(f"{key}="):
                    return line.split("=", 1)[1].strip()
    except OSError:
        pass
    return ""


def arr_stat(app, cfg):
    key = read_api_key(app)
    if not key:
        return None
    headers = {"X-Api-Key": key}
    base = f"http://localhost:{cfg['port']}/api/{cfg['api_ver']}"
    queue = api(f"{base}/queue?pageSize=1", headers)
    missing = api(f"{base}/wanted/missing?pageSize=1", headers)
    if queue is None or missing is None:
        return None
    q = queue.get("totalRecords", 0)
    m = missing.get("totalRecords", 0)
    return f"{q} queued · {m} missing"


def prowlarr_stat():
    key = read_api_key("prowlarr")
    if not key:
        return None
    indexers = api("http://localhost:9696/api/v1/indexer", {"X-Api-Key": key})
    if indexers is None:
        return None
    enabled = sum(1 for i in indexers if i.get("enable"))
    return f"{enabled}/{len(indexers)} indexers enabled"


def sabnzbd_stat():
    key = None
    try:
        with open(f"{APPDATA}/sabnzbd/sabnzbd.ini") as f:
            for line in f:
                if line.strip().startswith("api_key"):
                    key = line.split("=", 1)[1].strip()
                    break
    except OSError:
        pass
    if not key:
        return None
    result = api(f"http://localhost:8085/api?mode=queue&output=json&apikey={key}")
    if result is None:
        return None
    q = result.get("queue", {})
    slots = int(q.get("noofslots", 0) or 0)
    speed_kb = float(q.get("kbpersec", 0) or 0)
    if slots == 0:
        return "idle"
    if speed_kb >= 1024:
        return f"{slots} active · {speed_kb / 1024:.1f} MB/s"
    return f"{slots} active · {speed_kb:.0f} KB/s"


def jellyfin_stat():
    key = read_env("JELLYFIN_API_KEY")
    if not key:
        return None
    headers = {"Authorization": f'MediaBrowser Token="{key}"'}
    sessions = api("http://localhost:8096/Sessions", headers)
    if sessions is None:
        return None
    playing = sum(1 for s in sessions if s.get("NowPlayingItem"))
    if playing:
        return f"{playing} streaming"
    return "idle"


def _arr_stat_func(app, cfg):
    return lambda: arr_stat(app, cfg)


STAT_FUNCS = {"prowlarr": prowlarr_stat, "sabnzbd": sabnzbd_stat, "jellyfin": jellyfin_stat}
for _app, _cfg in ARR_APPS.items():
    STAT_FUNCS[_app] = _arr_stat_func(_app, _cfg)


def docker_status():
    out = subprocess.run(
        ["docker", "compose", "ps", "-a", "--format", "json"],
        cwd=INSTALL_ROOT, capture_output=True, text=True,
    ).stdout
    status = {}
    for line in out.splitlines():
        line = line.strip()
        if not line:
            continue
        d = json.loads(line)
        service = d.get("Service", "")
        if not service:
            continue
        state = d.get("State", "")
        health = d.get("Health", "") or "-"
        if state != "running":
            status[service] = "down"
        elif health not in ("-", "healthy"):
            status[service] = "starting"
        else:
            status[service] = "up"
    return status


def full_container_ids():
    ids = subprocess.run(
        ["docker", "compose", "ps", "-aq"],
        cwd=INSTALL_ROOT, capture_output=True, text=True,
    ).stdout.split()
    if not ids:
        return {}
    out = subprocess.run(
        ["docker", "inspect", "--format",
         '{{index .Config.Labels "com.docker.compose.service"}}\t{{.Id}}'] + ids,
        capture_output=True, text=True,
    ).stdout
    result = {}
    for line in out.splitlines():
        if "\t" in line:
            svc, cid = line.split("\t", 1)
            result[svc] = cid
    return result


def send_ntfy(topic, title, priority, tags, message):
    req = urllib.request.Request(
        f"https://ntfy.sh/{topic}",
        data=message.encode(),
        headers={"Title": title, "Priority": priority, "Tags": tags},
        method="POST",
    )
    try:
        urllib.request.urlopen(req, timeout=10).read()
    except (urllib.error.URLError, urllib.error.HTTPError, TimeoutError, OSError):
        pass


def fire_alerts(cur_status, topic):
    state_dir = f"{INSTALL_ROOT}/.state"
    prev_file = f"{state_dir}/prev_status.txt"
    os.makedirs(state_dir, exist_ok=True)

    first_run = not os.path.exists(prev_file)
    prev_status = {}
    if not first_run:
        with open(prev_file) as f:
            for line in f:
                if "=" in line:
                    svc, st = line.strip().split("=", 1)
                    prev_status[svc] = st

    if not first_run:
        for service, new in cur_status.items():
            old = prev_status.get(service, "")
            display = service.capitalize()
            if old != "down" and new == "down":
                send_ntfy(topic, f"{display} is down", "urgent", "rotating_light",
                           f"{display} on this media server just went offline.")
            elif old == "down" and new == "up":
                send_ntfy(topic, f"{display} is back up", "default", "white_check_mark",
                           f"{display} on this media server is back online.")

    with open(prev_file, "w") as f:
        for service, st in cur_status.items():
            f.write(f"{service}={st}\n")


def main():
    cur_status = docker_status()
    full_ids = full_container_ids()

    services = {}
    for service, status in cur_status.items():
        entry = {"status": status, "id": full_ids.get(service, "")}
        stat_func = STAT_FUNCS.get(service)
        if stat_func and status == "up":
            stat = stat_func()
            if stat:
                entry["stat"] = stat
        services[service] = entry

    topic = read_env("NTFY_TOPIC")
    if topic:
        fire_alerts(cur_status, topic)

    print(json.dumps(services))


if __name__ == "__main__":
    main()
