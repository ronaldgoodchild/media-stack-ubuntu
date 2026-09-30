# Changelog

## [Unreleased] - first public release
- Docker Compose media stack for Ubuntu Server 24.04/26.04: Prowlarr, Sonarr, Radarr, Lidarr, Readarr, Whisparr (optional), Bazarr, SABnzbd, qBittorrent behind a Mullvad WireGuard kill switch, Jellyfin, Seerr, Recyclarr, arr-dashboard, Portainer, Watchtower, Nginx Proxy Manager, Samba shares and a status dashboard.
- **Public release changes**
  - Prowlarr is installed with **no indexers**; the auto-add public-indexer helper was removed. Choosing indexers is up to you.
  - **No default password.** `tools/wire-stack.py` generates a random 20-character password on first run, prints it, and saves it to `credentials.txt` (mode 600); re-runs reuse it. `--password` still overrides it.
  - The pre-filled Usenet-provider entry in SABnzbd was removed; add your own provider in SABnzbd.
  - Docs point at the public Windows sibling, `media-stack-installer`; MIT license, security policy and CI added.
