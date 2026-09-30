#!/bin/bash
# =============================================================
# REGTeches Media Stack — Ubuntu Server Uninstaller
# =============================================================
set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BOLD='\033[1m'; NC='\033[0m'
log()  { echo -e "${GREEN}[OK]${NC} $1"; }
warn() { echo -e "${YELLOW}[!]${NC} $1"; }
error(){ echo -e "${RED}[X]${NC} $1"; exit 1; }

usage() {
  cat <<EOF
Usage: sudo ./uninstall.sh [flags]

  --install-root PATH   Stack's compose/env location (default: /opt/mediastack)
  --media-root PATH     Media/downloads/appdata location (default: /mnt/media)
  --purge-data          Also delete \$INSTALL_ROOT (compose file, .env — NOT your media)
  --purge-media         Also delete \$MEDIA_ROOT — YOUR ACTUAL MEDIA LIBRARY. Separate flag
                         from --purge-data on purpose so this never happens by accident.
  --keep-samba          Leave the Samba config/shares alone
  -h, --help             Show this help

Always stops and removes the containers + the boot-time systemd service first.
Docker images themselves are left alone — remove with 'docker image prune -a' if wanted.
EOF
}

INSTALL_ROOT="/opt/mediastack"
MEDIA_ROOT="/mnt/media"
PURGE_DATA=false
PURGE_MEDIA=false
KEEP_SAMBA=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --install-root) INSTALL_ROOT="$2"; shift 2 ;;
    --media-root) MEDIA_ROOT="$2"; shift 2 ;;
    --purge-data) PURGE_DATA=true; shift ;;
    --purge-media) PURGE_MEDIA=true; shift ;;
    --keep-samba) KEEP_SAMBA=true; shift ;;
    -h|--help) usage; exit 0 ;;
    *) error "Unknown flag: $1 (see --help)" ;;
  esac
done

[[ "$EUID" -eq 0 ]] || error "Run as root: sudo ./uninstall.sh"

if [[ -f "${INSTALL_ROOT}/docker-compose.yml" ]]; then
  echo "Stopping and removing containers..."
  # Enumerate every optional profile explicitly so containers get torn down
  # even if .env's COMPOSE_PROFILES was edited/narrowed after install.
  (cd "${INSTALL_ROOT}" && docker compose \
    --profile qbittorrent --profile sabnzbd \
    --profile bazarr --profile lidarr --profile readarr --profile whisparr \
    --profile seerr --profile recyclarr --profile arr-dashboard \
    --profile npm \
    down --remove-orphans)
  log "Containers stopped and removed"
else
  warn "No docker-compose.yml at ${INSTALL_ROOT} — skipping container teardown"
fi

if [[ -f /etc/systemd/system/mediastack.service ]]; then
  systemctl disable --now mediastack.service 2>/dev/null || true
  rm -f /etc/systemd/system/mediastack.service
  systemctl daemon-reload
  log "mediastack.service removed"
fi

if command -v ufw &>/dev/null; then
  for port in 8090/tcp 9000/tcp 9443/tcp 8096/tcp 9696/tcp 8989/tcp 7878/tcp \
              8686/tcp 6767/tcp 8088/tcp 6881/tcp 6881/udp 8085/tcp 6789/tcp \
              80/tcp 81/tcp 443/tcp; do
    ufw delete allow "$port" 2>/dev/null || true
  done
  log "Firewall rules removed (ufw itself left enabled)"
fi

if [[ "$KEEP_SAMBA" == false ]]; then
  if [[ -f /etc/samba/smb.conf.bak ]]; then
    mv /etc/samba/smb.conf.bak /etc/samba/smb.conf
    systemctl restart smbd nmbd 2>/dev/null || true
    log "Samba config restored to its pre-install state"
  else
    warn "No smb.conf.bak found — leaving Samba config as-is"
  fi
fi

if [[ "$PURGE_DATA" == true ]]; then
  rm -rf "${INSTALL_ROOT}"
  log "Deleted ${INSTALL_ROOT} (.env, docker-compose.yml, dashboard)"
else
  warn "Left ${INSTALL_ROOT} in place (pass --purge-data to remove it)"
fi

if [[ "$PURGE_MEDIA" == true ]]; then
  warn "Deleting ${MEDIA_ROOT} — your media library, downloads, and every app's config..."
  rm -rf "${MEDIA_ROOT}"
  log "Deleted ${MEDIA_ROOT}"
else
  log "Left ${MEDIA_ROOT} in place — your media/downloads/appdata are untouched"
fi

echo ""
log "Uninstall complete. Docker itself, and the ${STACK_USER:-stack} user, were left alone."
