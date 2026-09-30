#!/usr/bin/env python3
"""Wires the whole stack together after install.sh:
  - Sets forms auth (username 'media'; password generated on first run, or pass --password) on Sonarr, Radarr, Lidarr, Bazarr
  - Adds each app's root folder (pointed at the big media drive)
  - Registers SABnzbd as a download client in Sonarr/Radarr/Lidarr/Whisparr
  - Registers Sonarr/Radarr/Lidarr as Applications in Prowlarr (so any
    indexers you add there sync out)
  - Connects Bazarr to Sonarr + Radarr
  - Sets SABnzbd's WebUI login and category folders

Run once, from the server, after the stack is up:
  python3 tools/wire-stack.py

Does NOT touch any indexer or Usenet-provider credentials - those are yours to add.
"""
import argparse
import json
import os
import re
import secrets
import socket
import string
import sys
import urllib.error
import urllib.parse
import urllib.request

APPDATA = "/mnt/media/AppData"

APPS = {
    "sonarr":   {"port": 8989, "api_ver": "v3", "root": "/tv",     "category": "tv",     "cat_field": "tvCategory"},
    "radarr":   {"port": 7878, "api_ver": "v3", "root": "/movies", "category": "movies", "cat_field": "movieCategory"},
    "lidarr":   {"port": 8686, "api_ver": "v1", "root": "/music",  "category": "music",  "cat_field": "musicCategory"},
    "whisparr": {"port": 6969, "api_ver": "v3", "root": "/adult",  "category": "adult",  "cat_field": "movieCategory"},
    # Readarr's download-client field is literally named "musicCategory" —
    # not a typo, its codebase inherited Lidarr's field naming and it was
    # never renamed for books. Confirmed against its own schema endpoint.
    "readarr":  {"port": 8787, "api_ver": "v1", "root": "/books",  "category": "books",  "cat_field": "musicCategory"},
}


def read_api_key(app):
    with open(f"{APPDATA}/{app}/config.xml") as f:
        content = f.read()
    m = re.search(r"<ApiKey>([^<]+)</ApiKey>", content)
    if not m:
        raise SystemExit(f"Couldn't find <ApiKey> for {app}")
    return m.group(1)


def api(url, headers=None, method="GET", body=None, form=False, timeout=20):
    headers = dict(headers or {})
    data = None
    if body is not None:
        if form:
            data = urllib.parse.urlencode(body).encode()
        else:
            data = json.dumps(body).encode()
            headers["Content-Type"] = "application/json"
    req = urllib.request.Request(url, data=data, headers=headers, method=method)
    try:
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            raw = resp.read()
            return resp.status, (json.loads(raw) if raw else None)
    except urllib.error.HTTPError as e:
        raw = e.read()
        try:
            return e.code, json.loads(raw)
        except Exception:
            return e.code, raw.decode(errors="replace")
    except (urllib.error.URLError, socket.timeout, TimeoutError) as e:
        return 0, str(e)


def set_field(schema_obj, name, value):
    for f in schema_obj["fields"]:
        if f["name"] == name:
            f["value"] = value


def wire_arr_app(app, cfg, username, password):
    key = read_api_key(app)
    base = f"http://localhost:{cfg['port']}/api/{cfg['api_ver']}"
    headers = {"X-Api-Key": key}
    print(f"\n=== {app} ===")

    # Auth
    status, host_cfg = api(f"{base}/config/host", headers)
    if status != 200:
        print(f"  ! couldn't read config/host: HTTP {status} {host_cfg}")
    else:
        host_cfg.update({
            "authenticationMethod": "forms",
            "authenticationRequired": "enabled",
            "username": username,
            "password": password,
            "passwordConfirmation": password,
        })
        status, result = api(f"{base}/config/host", headers, method="PUT", body=host_cfg)
        print(f"  auth -> HTTP {status}" + ("" if status == 202 or status == 200 else f" {result}"))

    # Root folder
    status, existing = api(f"{base}/rootfolder", headers)
    if status == 200 and not any(rf["path"] == cfg["root"] for rf in existing):
        rf_body = {"path": cfg["root"], "name": cfg["root"]}
        if app in ("lidarr", "readarr"):
            # Lidarr and Readarr's rootfolder needs a default quality/
            # metadata profile id (Sonarr/Radarr don't require this) — use
            # whichever profile is first/default in a fresh install.
            _, qprofiles = api(f"{base}/qualityprofile", headers)
            _, mprofiles = api(f"{base}/metadataprofile", headers)
            rf_body["defaultQualityProfileId"] = qprofiles[0]["id"]
            rf_body["defaultMetadataProfileId"] = mprofiles[0]["id"]
            rf_body["defaultMonitorOption"] = "all"
            rf_body["defaultNewItemMonitorOption"] = "all"
            rf_body["defaultTags"] = []
        status, result = api(f"{base}/rootfolder", headers, method="POST", body=rf_body)
        print(f"  root folder {cfg['root']} -> HTTP {status}" + ("" if status in (200, 201) else f" {result}"))
    else:
        print(f"  root folder {cfg['root']} already present")

    # Download clients
    status, dc_schema = api(f"{base}/downloadclient/schema", headers)
    status, dc_existing = api(f"{base}/downloadclient", headers)
    existing_names = {d["name"] for d in dc_existing} if status == 200 else set()

    def add_client(impl, name, host, port, extra_fields):
        if name in existing_names:
            print(f"  {name} download client already present")
            return
        schema = next(s for s in dc_schema if s["implementation"] == impl)
        payload = dict(schema)
        payload["name"] = name
        payload["enable"] = True
        set_field(payload, "host", host)
        set_field(payload, "port", port)
        for fname, fval in extra_fields.items():
            set_field(payload, fname, fval)
        status, result = api(f"{base}/downloadclient", headers, method="POST", body=payload)
        print(f"  + {name} -> HTTP {status}" + ("" if status in (200, 201) else f" {result}"))

    sab_key = read_sabnzbd_api_key()
    add_client("Sabnzbd", "SABnzbd", "sabnzbd", 8080, {
        "apiKey": sab_key, cfg["cat_field"]: cfg["category"],
    })


def read_sabnzbd_api_key():
    with open(f"{APPDATA}/sabnzbd/sabnzbd.ini") as f:
        for line in f:
            if line.strip().startswith("api_key"):
                return line.split("=", 1)[1].strip()
    raise SystemExit("Couldn't find api_key in sabnzbd.ini")


def register_in_prowlarr(username, password):
    print("\n=== Prowlarr: registering Sonarr/Radarr/Lidarr as Applications ===")
    key = read_api_key("prowlarr")
    headers = {"X-Api-Key": key}
    base = "http://localhost:9696/api/v1"
    status, schema = api(f"{base}/applications/schema", headers)
    status, existing = api(f"{base}/applications", headers)
    existing_names = {a["name"] for a in existing} if status == 200 else set()

    for app, cfg in APPS.items():
        impl = app.capitalize()
        if impl in existing_names:
            print(f"  {impl} already registered")
            continue
        entry = next(s for s in schema if s["implementation"] == impl)
        payload = dict(entry)
        payload["name"] = impl
        payload["syncLevel"] = "fullSync"
        set_field(payload, "prowlarrUrl", "http://prowlarr:9696")
        set_field(payload, "baseUrl", f"http://{app}:{cfg['port']}")
        set_field(payload, "apiKey", read_api_key(app))
        status, result = api(f"{base}/applications", headers, method="POST", body=payload)
        print(f"  + {impl} -> HTTP {status}" + ("" if status in (200, 201) else f" {result}"))


def wire_bazarr(username, password):
    print("\n=== Bazarr ===")
    key = read_api_key("bazarr") if False else None  # Bazarr key comes from its own config, not config.xml
    with open(f"{APPDATA}/bazarr/config/config.yaml") as f:
        content = f.read()
    m = re.search(r"apikey:\s*(\S+)", content)
    key = m.group(1)
    headers = {"X-API-KEY": key}
    base = "http://localhost:6767/api/system/settings"

    def save(fields):
        return api(base, headers, method="POST", body=fields, form=True)

    status, _ = save({
        "settings-general-use_sonarr": "true",
        "settings-sonarr-ip": "sonarr",
        "settings-sonarr-port": "8989",
        "settings-sonarr-apikey": read_api_key("sonarr"),
        "settings-sonarr-base_url": "/",
        "settings-sonarr-ssl": "false",
    })
    print(f"  link Sonarr -> HTTP {status}")

    status, _ = save({
        "settings-general-use_radarr": "true",
        "settings-radarr-ip": "radarr",
        "settings-radarr-port": "7878",
        "settings-radarr-apikey": read_api_key("radarr"),
        "settings-radarr-base_url": "/",
        "settings-radarr-ssl": "false",
    })
    print(f"  link Radarr -> HTTP {status}")

    status, _ = save({
        "settings-auth-type": "form",
        "settings-auth-username": username,
        "settings-auth-password": password,
    })
    print(f"  auth -> HTTP {status}")


def wire_sabnzbd(username, password):
    print("\n=== SABnzbd ===")
    key = read_sabnzbd_api_key()
    base = "http://localhost:8085/api"

    def call(mode, **params):
        params.update(mode=mode, apikey=key, output="json")
        status, result = api(f"{base}?{urllib.parse.urlencode(params)}", method="POST")
        return status, result

    status, _ = call("set_config", section="misc", keyword="username", value=username)
    status2, _ = call("set_config", section="misc", keyword="password", value=password)
    print(f"  WebUI login {username}/{'*' * len(password)} -> HTTP {status}/{status2}")

    # Sonarr/Radarr/Lidarr reach SABnzbd via the docker-compose service name
    # ("sabnzbd"), not localhost — without it in host_whitelist every
    # download-client connection test gets a 403.
    status, _ = call("set_config", section="misc", keyword="host_whitelist",
                      value="sabnzbd,localhost")
    print(f"  host_whitelist -> HTTP {status}")

    # SABnzbd's own default complete_dir/download_dir are RELATIVE
    # ("Downloads/complete"), which it resolves against its own /config
    # volume — not the shared /downloads volume every *arr app actually
    # mounts. Left alone, completed downloads land somewhere Sonarr/Radarr/
    # etc. can never see, and imports silently never happen.
    status, _ = call("set_config", section="misc", keyword="complete_dir", value="/downloads/complete")
    status2, _ = call("set_config", section="misc", keyword="download_dir", value="/downloads/incomplete")
    print(f"  complete_dir/download_dir -> absolute /downloads paths (HTTP {status}/{status2})")

    for cat in ("tv", "movies", "music", "books", "adult"):
        status, _ = call("set_config", section="categories", keyword=cat, name=cat, dir=cat)
        print(f"  category '{cat}' -> HTTP {status}")


CRED_FILE = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "credentials.txt")


def resolve_password(given):
    """Use --password if given; else reuse the saved one; else generate and save a random one."""
    if given:
        return given, False
    if os.path.exists(CRED_FILE):
        for line in open(CRED_FILE, encoding="utf-8"):
            if line.startswith("password="):
                return line.split("=", 1)[1].strip(), False
    alphabet = string.ascii_letters + string.digits
    pw = "".join(secrets.choice(alphabet) for _ in range(20))
    fd = os.open(CRED_FILE, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(fd, "w", encoding="utf-8") as f:
        f.write("username=media" + chr(10) + "password=" + pw + chr(10))
    return pw, True


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--username", default="media")
    ap.add_argument("--password", default=None,
                    help="Login password for every app. Omit it and a random one is generated on "
                         "first run, printed at the end and saved (mode 600) in credentials.txt next "
                         "to the install root; re-runs reuse it.")
    args = ap.parse_args()
    args.password, generated = resolve_password(args.password)

    # SABnzbd auth + host_whitelist need to be correct BEFORE the *arr apps
    # test-connect to it as a download client.
    wire_sabnzbd(args.username, args.password)

    for app, cfg in APPS.items():
        wire_arr_app(app, cfg, args.username, args.password)

    register_in_prowlarr(args.username, args.password)
    wire_bazarr(args.username, args.password)

    print("\nDone. Login for every app -> username: %s" % args.username)
    print("Password: %s" % args.password)
    if generated:
        print("(generated just now and saved to %s)" % CRED_FILE)
    print("Next: add your indexers in Prowlarr and your own download-client logins.")


if __name__ == "__main__":
    main()
