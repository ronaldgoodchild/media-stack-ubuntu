#!/bin/bash
# =============================================================
# REGTeches Media Stack — Update
# =============================================================
# Watchtower already updates every container automatically once a day.
# This script is for pulling updates on demand instead of waiting.
set -euo pipefail

GREEN='\033[0;32m'; BOLD='\033[1m'; NC='\033[0m'
log() { echo -e "${GREEN}[OK]${NC} $1"; }

usage() {
  cat <<EOF
Usage: sudo ./update.sh [flags]

  --install-root PATH   Stack's compose/env location (default: /opt/mediastack)
  --prune                Also remove now-unused images after updating (docker image prune -f)
  -h, --help              Show this help
EOF
}

INSTALL_ROOT="/opt/mediastack"
PRUNE=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --install-root) INSTALL_ROOT="$2"; shift 2 ;;
    --prune) PRUNE=true; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown flag: $1 (see --help)"; exit 1 ;;
  esac
done

[[ "$EUID" -eq 0 ]] || { echo "Run as root: sudo ./update.sh"; exit 1; }
[[ -f "${INSTALL_ROOT}/docker-compose.yml" ]] || { echo "No stack found at ${INSTALL_ROOT}"; exit 1; }

cd "${INSTALL_ROOT}"
echo "Pulling latest images..."
docker compose pull
log "Images pulled"

echo "Recreating any containers that changed..."
docker compose up -d --remove-orphans
log "Stack updated — config and app data (config.xml/databases) are untouched"

if [[ "$PRUNE" == true ]]; then
  docker image prune -f
  log "Unused images pruned"
fi
