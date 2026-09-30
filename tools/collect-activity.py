#!/usr/bin/env python3
"""Resolves the "activity" section of dashboard/stats.json: a merged, time-
sorted feed of recent grabs/imports across Sonarr, Radarr, Lidarr, Readarr,
and Whisparr, read straight from each app's own /history API (no local
state of our own to keep in sync). SABnzbd isn't queried separately — every
grab/import it hands off already shows up in the *arr app's own history,
so including it too would just duplicate each entry.

Called by update-stats.sh every 30s; not meant to be run by hand, though
harmless to. Prints the activity array as one line of JSON to stdout.
"""
import json
import re
import sys
import urllib.error
import urllib.request

APPDATA = "/mnt/media/AppData"
PER_APP_LIMIT = 10
FEED_LIMIT = 20

ARR_APPS = {
    "sonarr":   {"port": 8989, "api_ver": "v3"},
    "radarr":   {"port": 7878, "api_ver": "v3"},
    "lidarr":   {"port": 8686, "api_ver": "v1"},
    "readarr":  {"port": 8787, "api_ver": "v1"},
    "whisparr": {"port": 6969, "api_ver": "v3"},
}

# Only event types worth showing on a "what's happened lately" feed — a raw
# history dump also includes file-deleted/renamed/retagged noise nobody
# handing this server off cares about.
EVENT_LABELS = {
    "grabbed": ("Grabbed", "\U0001F4E5"),
    "downloadFolderImported": ("Imported", "✅"),
    "downloadFailed": ("Failed", "⚠️"),
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


def clean_title(source_title):
    title = source_title.replace(".", " ").strip()
    title = re.sub(r"\s+", " ", title)
    return title[:77] + "..." if len(title) > 80 else title


def app_history(app, cfg):
    key = read_api_key(app)
    if not key:
        return []
    url = (f"http://localhost:{cfg['port']}/api/{cfg['api_ver']}/history"
           f"?pageSize={PER_APP_LIMIT}&sortKey=date&sortDirection=descending")
    data = api(url, {"X-Api-Key": key})
    if not data:
        return []
    items = []
    for rec in data.get("records", []):
        label = EVENT_LABELS.get(rec.get("eventType"))
        if not label or not rec.get("sourceTitle") or not rec.get("date"):
            continue
        event, icon = label
        items.append({
            "app": app,
            "icon": icon,
            "event": event,
            "title": clean_title(rec["sourceTitle"]),
            "date": rec["date"],
        })
    return items


def main():
    feed = []
    for app, cfg in ARR_APPS.items():
        feed.extend(app_history(app, cfg))
    feed.sort(key=lambda i: i["date"], reverse=True)
    print(json.dumps(feed[:FEED_LIMIT]))


if __name__ == "__main__":
    main()
