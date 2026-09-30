# What's in this directory

A guide to every file in this repo, for whoever looks at it next. Mirrors the
layout of the Windows [media-stack-installer](https://github.com/ronaldgoodchild/media-stack-installer)
project.

## Files you actually run

| File | What it is | How to use it |
|---|---|---|
| **install.sh** | The real installer. Installs Docker, creates the directory tree, deploys `docker-compose.yml` + `dashboard/` to `--install-root`, writes `.env`, configures Samba, registers the `mediastack.service` systemd unit, starts the stack, opens firewall ports. | `sudo ./install.sh` (interactive) or with flags for unattended — see README.md for the full flag list. Safe to re-run. |
| **uninstall.sh** | Tears down every container (across all optional profiles, regardless of current `.env`), removes the systemd service and firewall rules, restores the original `smb.conf`. | `sudo ./uninstall.sh`. Add `--purge-data` to delete `--install-root` (compose file/.env) too, and `--purge-media` (separately, on purpose) to also delete your actual media library. |
| **update.sh** | Pulls newer images and recreates any container that changed. Watchtower already does this once a day on its own — this is for doing it on demand. | `sudo ./update.sh` (add `--prune` to also clean up now-unused images). |

## Files install.sh deploys for you

| File | What it is |
|---|---|
| **docker-compose.yml** | The stack definition — every service, its ports, volumes, and (for the six optional apps) its Compose profile. This is the source of truth; `install.sh` copies it into `--install-root` on every run, so edit *this* copy if you want the change to survive a re-install. |
| **dashboard/index.html** | The status page served at `:8090` — two tabs, no page reload. **Dashboard**: a static launcher with a card per app (reads the server's own hostname from the browser URL, so it's never hardcoded/stale) with a live status dot per app, a Storage + Memory panel fed by `stats.json`, right-click → Manage in Portainer on every card, and the SMB share paths with a copy button. **Help**: a plain-English walkthrough for whoever's actually using the box — what to click first, what every app does, the shared logins, SMB mapping steps. |
| **tools/update-stats.sh** | Writes `dashboard/stats.json` — disk usage (`df`), memory (`free`), Tailscale's connection state, and the ntfy.sh topic. Delegates the "services" section to `tools/collect-services.py` (see below). `install.sh` registers it as `mediastack-stats.timer`, running every 30s. Not meant to be run by hand, though it's harmless to. |
| **tools/collect-services.py** | Resolves every container's up/starting/down status plus its live full container ID (`docker compose ps` + a batch `docker inspect`, re-resolved every run since Watchtower changes IDs on auto-update). For apps whose API it knows (Sonarr/Radarr/Lidarr/Readarr/Whisparr, Prowlarr, SABnzbd, Jellyfin), also pulls a live one-line stat — queue/missing counts, indexer count, download speed, active streams — shown on the dashboard card in place of the static description. Also *does* something, not just reports: if `NTFY_TOPIC` is set in `.env`, it diffs each service's status against the previous run (kept in `.state/prev_status.txt`) and fires a push notification on an actual down/up transition — never on every poll, never on the first run after install. Jellyfin's stat needs `JELLYFIN_API_KEY` in `.env` (not set by `install.sh` — see README); every other app's key it reads straight from that app's own config on disk. |
| **tools/collect-activity.py** | Resolves the dashboard's "Recent Activity" feed — the last 20 grabs/imports across Sonarr/Radarr/Lidarr/Readarr/Whisparr, merged and sorted newest-first, read straight from each app's own `/history` API. No local state of its own; SABnzbd isn't queried separately since every one of its handoffs already shows up in the *arr app's own history. |
| **tools/wire-stack.py** | One-shot full wiring: forms auth (generated password, saved to credentials.txt) on Sonarr/Radarr/Lidarr/Readarr/Whisparr/Bazarr, root folders on the media drive, SABnzbd registered as a download client, Sonarr/Radarr/Lidarr/Readarr/Whisparr registered as Prowlarr Applications (so indexers sync automatically), Bazarr connected to Sonarr/Radarr, and a disabled Newshosting server pre-filled (host/port/SSL/connections) in SABnzbd — everything except the Newshosting username/password itself, left for you to type into SABnzbd's own UI. Idempotent; safe to re-run. See README.md. |
| **.env.example** | Reference only — shows every variable `install.sh` writes into the real `.env`. Not deployed anywhere; just documentation for anyone who wants to hand-build a `.env`. |

## Reference

| File | What it is |
|---|---|
| **README.md** | Full documentation — what the installer does, every flag, ports, folder layout, day-to-day commands, known gaps. Read this first. |

## Where the actual running stack lives

None of the above is the running stack itself — that's a separate deploy
target, by default `/opt/mediastack` (compose file + `.env` + dashboard) and
`/mnt/media` (your actual media/downloads/app configs) on whichever server
you ran `install.sh` on.
