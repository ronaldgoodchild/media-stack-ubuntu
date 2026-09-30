#!/bin/bash
# =============================================================
# REGTeches Media Stack — Ubuntu Server Installer
# =============================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; BOLD='\033[1m'; NC='\033[0m'
log()     { echo -e "${GREEN}[OK]${NC} $1"; }
warn()    { echo -e "${YELLOW}[!]${NC} $1"; }
error()   { echo -e "${RED}[X]${NC} $1"; exit 1; }
section() { echo -e "\n${BOLD}${BLUE}--- $1 ---${NC}"; }

print_banner() {
  echo -e "${BLUE}"
  echo "  REGTeches Media Stack — Ubuntu Server Installer"
  echo "  by Ronald Goodchild"
  echo -e "${NC}"
}

usage() {
  cat <<EOF
Usage: sudo ./install.sh [flags]

  --install-root PATH        Where the stack's compose/env files live (default: /opt/mediastack)
  --media-root PATH          Where your media/downloads/appdata live (default: /mnt/media)
  --stack-user NAME          System user that owns everything + runs Samba (default: \$SUDO_USER)
  --timezone TZ              Container timezone (default: America/New_York)
  --skip-apps LIST           Comma list to leave out: qbittorrent,sabnzbd,bazarr,lidarr,readarr,whisparr,seerr,recyclarr,arr-dashboard,npm
                              (skipping "qbittorrent" also skips the gluetun VPN container)
  --mullvad-private-key KEY  Mullvad WireGuard PrivateKey (required unless qbittorrent is skipped)
  --mullvad-address ADDR     Mullvad WireGuard Address, e.g. 10.x.x.x/32
  --vpn-country COUNTRY      Mullvad server country (default: USA)
  --smb-user NAME            Samba share username (default: same as --stack-user)
  --smb-password PASS        Samba share password (prompted if omitted and Samba isn't skipped)
  --skip-samba               Don't configure Samba shares
  --skip-firewall             Don't touch ufw
  --skip-tailscale             Don't install Tailscale
  --tailscale-authkey KEY     Join your tailnet unattended (from your Tailscale admin console -> Settings -> Keys); omit to approve it yourself in a browser after install
  --ntfy-topic TOPIC          ntfy.sh topic for down/back-up push alerts (random one generated if omitted; see https://ntfy.sh)
  --skip-ntfy                 Don't set up ntfy.sh alerting
  --force-env                Overwrite an existing .env instead of leaving it alone
  --non-interactive           Fail instead of prompting when a required value is missing
  -h, --help                  Show this help

Safe to re-run any time — existing config/data is left alone unless a flag says otherwise.
EOF
}

INSTALL_ROOT="/opt/mediastack"
MEDIA_ROOT="/mnt/media"
STACK_USER="${SUDO_USER:-}"
TIMEZONE="America/New_York"
SKIP_APPS=""
MULLVAD_PRIVATE_KEY=""
MULLVAD_ADDRESS=""
VPN_COUNTRY="USA"
SMB_USER=""
SMB_PASS=""
SKIP_SAMBA=false
SKIP_FIREWALL=false
SKIP_TAILSCALE=false
NTFY_TOPIC=""
SKIP_NTFY=false
TAILSCALE_AUTHKEY=""
FORCE_ENV=false
NON_INTERACTIVE=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --install-root) INSTALL_ROOT="$2"; shift 2 ;;
    --media-root) MEDIA_ROOT="$2"; shift 2 ;;
    --stack-user) STACK_USER="$2"; shift 2 ;;
    --timezone) TIMEZONE="$2"; shift 2 ;;
    --skip-apps) SKIP_APPS="$2"; shift 2 ;;
    --mullvad-private-key) MULLVAD_PRIVATE_KEY="$2"; shift 2 ;;
    --mullvad-address) MULLVAD_ADDRESS="$2"; shift 2 ;;
    --vpn-country) VPN_COUNTRY="$2"; shift 2 ;;
    --smb-user) SMB_USER="$2"; shift 2 ;;
    --smb-password) SMB_PASS="$2"; shift 2 ;;
    --skip-samba) SKIP_SAMBA=true; shift ;;
    --skip-firewall) SKIP_FIREWALL=true; shift ;;
    --skip-tailscale) SKIP_TAILSCALE=true; shift ;;
    --ntfy-topic) NTFY_TOPIC="$2"; shift 2 ;;
    --skip-ntfy) SKIP_NTFY=true; shift ;;
    --tailscale-authkey) TAILSCALE_AUTHKEY="$2"; shift 2 ;;
    --force-env) FORCE_ENV=true; shift ;;
    --non-interactive) NON_INTERACTIVE=true; shift ;;
    -h|--help) usage; exit 0 ;;
    *) error "Unknown flag: $1 (see --help)" ;;
  esac
done

[[ "$EUID" -eq 0 ]] || error "Run as root: sudo ./install.sh"
[[ -n "$STACK_USER" ]] || error "Couldn't determine a stack user — pass --stack-user NAME (or run with sudo as a normal user, not root's own shell)"
SMB_USER="${SMB_USER:-$STACK_USER}"

print_banner

# =============================================================
# Optional-app profile list
# =============================================================
ALL_OPTIONAL=(qbittorrent sabnzbd bazarr lidarr readarr whisparr seerr recyclarr arr-dashboard npm)
IFS=',' read -ra SKIP_ARR <<< "$SKIP_APPS"
ENABLED_PROFILES=()
for app in "${ALL_OPTIONAL[@]}"; do
  skip=false
  for s in "${SKIP_ARR[@]}"; do [[ "$s" == "$app" ]] && skip=true; done
  [[ "$skip" == false ]] && ENABLED_PROFILES+=("$app")
done
IFS=','; COMPOSE_PROFILES="${ENABLED_PROFILES[*]}"; IFS=$' \t\n'
is_enabled() { [[ ",$COMPOSE_PROFILES," == *",$1,"* ]]; }

# =============================================================
# Collect configuration
# =============================================================
section "Configuration"

if is_enabled qbittorrent && [[ -z "$MULLVAD_PRIVATE_KEY" || -z "$MULLVAD_ADDRESS" ]]; then
  if [[ "$NON_INTERACTIVE" == true ]]; then
    error "qbittorrent is enabled but --mullvad-private-key/--mullvad-address weren't given (or pass --skip-apps qbittorrent)"
  fi
  echo -e "${YELLOW}qBittorrent needs a Mullvad WireGuard config for its VPN kill switch.${NC}"
  echo -e "Get it at: ${BOLD}https://mullvad.net/en/account/wireguard-config${NC} (WireGuard, Linux, any server)"
  echo -e "Leave blank to skip qBittorrent/VPN entirely.\n"
  [[ -z "$MULLVAD_PRIVATE_KEY" ]] && read -rp "Mullvad WireGuard PrivateKey: " MULLVAD_PRIVATE_KEY
  if [[ -z "$MULLVAD_PRIVATE_KEY" ]]; then
    warn "No key given — dropping qbittorrent/gluetun from this install"
    ENABLED_PROFILES=("${ENABLED_PROFILES[@]/qbittorrent/}")
    IFS=','; COMPOSE_PROFILES="${ENABLED_PROFILES[*]}"; IFS=$' \t\n'
    COMPOSE_PROFILES="$(echo "$COMPOSE_PROFILES" | sed 's/,,*/,/g; s/^,//; s/,$//')"
  else
    [[ -z "$MULLVAD_ADDRESS" ]] && read -rp "Mullvad WireGuard Address (e.g. 10.x.x.x/32): " MULLVAD_ADDRESS
  fi
fi

if [[ "$SKIP_SAMBA" == false && -z "$SMB_PASS" ]]; then
  if [[ "$NON_INTERACTIVE" == true ]]; then
    error "Samba is enabled but --smb-password wasn't given (or pass --skip-samba)"
  fi
  read -rsp "Samba share password for user '${SMB_USER}': " SMB_PASS; echo ""
fi

log "Configuration collected. Enabled optional apps: ${COMPOSE_PROFILES:-none}"

# =============================================================
# System update + dependencies
# =============================================================
section "System Update"
apt-get update -qq && apt-get upgrade -y -qq
log "System updated"

section "Installing Dependencies"
apt-get install -y -qq curl wget git nano htop net-tools ca-certificates gnupg \
  lsb-release apt-transport-https software-properties-common
[[ "$SKIP_SAMBA" == false ]] && apt-get install -y -qq samba samba-common-bin avahi-daemon
log "Dependencies installed"

# =============================================================
# Docker
# =============================================================
section "Installing Docker"
if ! command -v docker &>/dev/null; then
  install -m 0755 -d /etc/apt/keyrings
  curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
  chmod a+r /etc/apt/keyrings/docker.gpg
  echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu $(. /etc/os-release && echo "$VERSION_CODENAME") stable" \
    > /etc/apt/sources.list.d/docker.list
  apt-get update -qq
  apt-get install -y -qq docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
  log "Docker installed"
else
  log "Docker already installed ($(docker --version))"
fi
systemctl enable --now docker
log "Docker running"

# =============================================================
# Stack user
# =============================================================
section "User Setup"
if ! id "$STACK_USER" &>/dev/null; then
  useradd -m -s /bin/bash "$STACK_USER"
  log "User ${STACK_USER} created"
else
  log "User ${STACK_USER} already exists"
fi
usermod -aG docker "$STACK_USER"
PUID=$(id -u "$STACK_USER"); PGID=$(id -g "$STACK_USER")

# =============================================================
# Directory structure
# =============================================================
section "Creating Directory Structure"
mkdir -p \
  "${MEDIA_ROOT}"/Media/{Movies,TV,Music,Books,Adult} \
  "${MEDIA_ROOT}"/Downloads/incomplete \
  "${MEDIA_ROOT}"/Downloads/complete/{tv,movies,music,books,adult} \
  "${MEDIA_ROOT}"/AppData/{jellyfin,sonarr,radarr,lidarr,readarr,whisparr,bazarr,prowlarr,qbittorrent,sabnzbd,gluetun,portainer,seerr,recyclarr,arr-dashboard} \
  "${MEDIA_ROOT}"/AppData/npm/{data,letsencrypt} \
  "${MEDIA_ROOT}"/Shared
chown -R "${STACK_USER}:${STACK_USER}" "${MEDIA_ROOT}"
chmod -R 775 "${MEDIA_ROOT}"
log "Directory structure ready at ${MEDIA_ROOT}"

mkdir -p "${INSTALL_ROOT}"
cp -f "${SCRIPT_DIR}/docker-compose.yml" "${INSTALL_ROOT}/docker-compose.yml"
mkdir -p "${INSTALL_ROOT}/dashboard"
cp -rf "${SCRIPT_DIR}/dashboard/." "${INSTALL_ROOT}/dashboard/"
mkdir -p "${INSTALL_ROOT}/tools"
cp -f "${SCRIPT_DIR}/tools/update-stats.sh" "${INSTALL_ROOT}/tools/update-stats.sh"
cp -f "${SCRIPT_DIR}/tools/collect-services.py" "${INSTALL_ROOT}/tools/collect-services.py"
cp -f "${SCRIPT_DIR}/tools/collect-activity.py" "${INSTALL_ROOT}/tools/collect-activity.py"
cp -f "${SCRIPT_DIR}/tools/wire-stack.py" "${INSTALL_ROOT}/tools/wire-stack.py"
chmod +x "${INSTALL_ROOT}/tools/update-stats.sh" "${INSTALL_ROOT}/tools/collect-services.py" "${INSTALL_ROOT}/tools/collect-activity.py" "${INSTALL_ROOT}/tools/wire-stack.py"
log "docker-compose.yml + dashboard + tools deployed to ${INSTALL_ROOT}"

# =============================================================
# .env
# =============================================================
if [[ "$SKIP_NTFY" == false && -z "$NTFY_TOPIC" ]]; then
  # A public ntfy.sh topic is security-through-obscurity — anyone who knows
  # the name can read or post to it — so generate an unguessable one rather
  # than something predictable like the hostname.
  NTFY_TOPIC="regteches-mediastack-$(tr -dc 'a-z0-9' </dev/urandom | head -c 12)"
fi

section "Writing Environment Config"
if [[ -f "${INSTALL_ROOT}/.env" && "$FORCE_ENV" == false ]]; then
  warn "${INSTALL_ROOT}/.env already exists — leaving it alone (pass --force-env to regenerate)"
else
  cat > "${INSTALL_ROOT}/.env" <<EOF
# REGTeches Media Stack - generated by install.sh $(date -Iseconds)
PUID=${PUID}
PGID=${PGID}
TZ=${TIMEZONE}
MEDIA_ROOT=${MEDIA_ROOT}
MULLVAD_PRIVATE_KEY=${MULLVAD_PRIVATE_KEY}
MULLVAD_ADDRESS=${MULLVAD_ADDRESS}
VPN_COUNTRY=${VPN_COUNTRY}
COMPOSE_PROFILES=${COMPOSE_PROFILES}
NTFY_TOPIC=${NTFY_TOPIC}
EOF
  chmod 600 "${INSTALL_ROOT}/.env"
  log ".env written to ${INSTALL_ROOT}/.env"
fi
chown -R "${STACK_USER}:${STACK_USER}" "${INSTALL_ROOT}"
chmod 600 "${INSTALL_ROOT}/.env"

# =============================================================
# Samba
# =============================================================
if [[ "$SKIP_SAMBA" == false ]]; then
  section "Configuring Samba"
  [[ -f /etc/samba/smb.conf.bak ]] || cp /etc/samba/smb.conf /etc/samba/smb.conf.bak
  cat > /etc/samba/smb.conf <<EOF
[global]
   workgroup = WORKGROUP
   server string = REGTeches Media Server
   server role = standalone server
   log file = /var/log/samba/log.%m
   max log size = 1000
   logging = file
   panic action = /usr/share/samba/panic-action %d
   obey pam restrictions = yes
   unix password sync = yes
   passwd program = /usr/bin/passwd %u
   passwd chat = *Enter\snew\s*\spassword:* %n\n *Retype\snew\s*\spassword:* %n\n *password\supdated\ssuccessfully* .
   pam password change = yes
   map to guest = bad user
   usershare allow guests = yes

[Media]
   comment = Media Library
   path = ${MEDIA_ROOT}/Media
   browseable = yes
   read only = no
   guest ok = no
   valid users = ${SMB_USER}
   create mask = 0775
   directory mask = 0775
   force group = ${STACK_USER}

[Downloads]
   comment = Downloads
   path = ${MEDIA_ROOT}/Downloads
   browseable = yes
   read only = no
   guest ok = no
   valid users = ${SMB_USER}
   create mask = 0775
   directory mask = 0775

[Shared]
   comment = Shared Files
   path = ${MEDIA_ROOT}/Shared
   browseable = yes
   read only = no
   guest ok = no
   valid users = ${SMB_USER}
   create mask = 0775
   directory mask = 0775
EOF
  if [[ -n "$SMB_PASS" ]]; then
    (echo "$SMB_PASS"; echo "$SMB_PASS") | smbpasswd -a "$SMB_USER" -s
    smbpasswd -e "$SMB_USER"
  else
    warn "No Samba password set for ${SMB_USER} — run: sudo smbpasswd -a ${SMB_USER}"
  fi
  systemctl enable smbd nmbd
  systemctl restart smbd nmbd
  log "Samba configured — shares: Media, Downloads, Shared"
else
  warn "Skipping Samba (--skip-samba)"
fi

# =============================================================
# systemd auto-start
# =============================================================
section "Setting Up Auto-Start"
cat > /etc/systemd/system/mediastack.service <<EOF
[Unit]
Description=REGTeches Media Stack
Requires=docker.service
After=docker.service network-online.target
Wants=network-online.target

[Service]
Type=oneshot
RemainAfterExit=yes
WorkingDirectory=${INSTALL_ROOT}
ExecStart=/usr/bin/docker compose up -d --remove-orphans
ExecStop=/usr/bin/docker compose down
TimeoutStartSec=300

[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload
systemctl enable mediastack.service
log "mediastack.service enabled — stack starts on every boot"

section "Setting Up Dashboard Stats"
cat > /etc/systemd/system/mediastack-stats.service <<EOF
[Unit]
Description=REGTeches Media Stack - refresh dashboard stats (disk/memory/service status)

[Service]
Type=oneshot
ExecStart=${INSTALL_ROOT}/tools/update-stats.sh ${INSTALL_ROOT}
EOF
cat > /etc/systemd/system/mediastack-stats.timer <<EOF
[Unit]
Description=REGTeches Media Stack - refresh dashboard stats every 30s

[Timer]
OnBootSec=10s
OnUnitActiveSec=30s

[Install]
WantedBy=timers.target
EOF
systemctl daemon-reload
systemctl enable --now mediastack-stats.timer
log "Dashboard stats (storage/memory/service status) refreshing every 30s"

# =============================================================
# Start the stack
# =============================================================
section "Starting Media Stack"
cd "${INSTALL_ROOT}"
docker compose up -d --remove-orphans
log "Stack started"

# =============================================================
# Firewall
# =============================================================
if [[ "$SKIP_FIREWALL" == false ]] && command -v ufw &>/dev/null; then
  section "Configuring Firewall"
  ufw allow ssh
  ufw allow 8090/tcp   # Dashboard
  ufw allow 9000/tcp   # Portainer HTTP
  ufw allow 9443/tcp   # Portainer HTTPS
  ufw allow 8096/tcp   # Jellyfin
  ufw allow 9696/tcp   # Prowlarr
  ufw allow 8989/tcp   # Sonarr
  ufw allow 7878/tcp   # Radarr
  is_enabled qbittorrent && { ufw allow 8088/tcp; ufw allow 6881/tcp; ufw allow 6881/udp; }
  is_enabled sabnzbd && ufw allow 8085/tcp
  is_enabled lidarr && ufw allow 8686/tcp
  is_enabled readarr && ufw allow 8787/tcp
  is_enabled whisparr && ufw allow 6969/tcp
  is_enabled seerr && ufw allow 5055/tcp
  is_enabled arr-dashboard && ufw allow 3050/tcp
  is_enabled bazarr && ufw allow 6767/tcp
  is_enabled npm && { ufw allow 80/tcp; ufw allow 81/tcp; ufw allow 443/tcp; }
  if [[ "$SKIP_SAMBA" == false ]]; then
    ufw allow 137/udp; ufw allow 138/udp; ufw allow 139/tcp; ufw allow 445/tcp
  fi
  ufw --force enable
  log "Firewall configured"
else
  warn "Skipping firewall configuration"
fi

# =============================================================
# Tailscale
# =============================================================
TAILSCALE_JOINED=false
if [[ "$SKIP_TAILSCALE" == false ]]; then
  section "Installing Tailscale"
  if ! command -v tailscale &>/dev/null; then
    curl -fsSL https://tailscale.com/install.sh | sh
  fi
  if [[ -n "$TAILSCALE_AUTHKEY" ]]; then
    tailscale up --authkey "$TAILSCALE_AUTHKEY" --hostname="mediastack" && TAILSCALE_JOINED=true
    log "Joined your tailnet"
  else
    warn "Tailscale installed but not joined — run 'sudo tailscale up' and open the printed link to approve it (decide first which Tailscale account should own this box)"

    # Whoever ends up owning this box (could be someone other than whoever
    # ran install.sh) needs the join link but shouldn't need SSH commands to
    # find it — surface it on every login until it's actually joined. The
    # grep on "Logged out" makes this self-clearing: once tailscale status
    # stops reporting that, the block just stops printing on its own.
    cat > /etc/update-motd.d/99-tailscale-setup <<'MOTDEOF'
#!/bin/bash
command -v tailscale >/dev/null 2>&1 || exit 0
status_out=$(tailscale status 2>&1)
if echo "$status_out" | grep -q "^Logged out"; then
  url=$(echo "$status_out" | grep -oE "https://login\.tailscale\.com/a/[A-Za-z0-9]+")
  echo ""
  echo "=========================================================="
  echo "  TAILSCALE SETUP NEEDED"
  echo "  This server is not on a Tailscale network yet."
  echo "  Open this link in YOUR OWN browser and sign in with your"
  echo "  own Tailscale account (free) to connect it:"
  echo ""
  echo "  ${url:-run: sudo tailscale up}"
  echo ""
  echo "=========================================================="
  echo ""
fi
MOTDEOF
    chmod +x /etc/update-motd.d/99-tailscale-setup
    log "Join link will show on every SSH login until connected (/etc/update-motd.d/99-tailscale-setup)"
  fi
else
  warn "Skipping Tailscale"
fi

# =============================================================
# Summary
# =============================================================
SERVER_IP=$(hostname -I | awk '{print $1}')
echo ""
echo -e "${GREEN}${BOLD}================================================${NC}"
echo -e "${GREEN}${BOLD}  REGTeches Media Stack — Installation Complete${NC}"
echo -e "${GREEN}${BOLD}================================================${NC}"
echo ""
echo -e "${BOLD}Server IP:${NC} ${SERVER_IP}"
echo ""
echo -e "${BOLD}Dashboard:${NC}      http://${SERVER_IP}:8090"
echo -e "${BOLD}Portainer:${NC}      http://${SERVER_IP}:9000"
echo -e "${BOLD}Jellyfin:${NC}       http://${SERVER_IP}:8096"
echo -e "${BOLD}Prowlarr:${NC}       http://${SERVER_IP}:9696"
echo -e "${BOLD}Sonarr:${NC}         http://${SERVER_IP}:8989"
echo -e "${BOLD}Radarr:${NC}         http://${SERVER_IP}:7878"
is_enabled lidarr     && echo -e "${BOLD}Lidarr:${NC}         http://${SERVER_IP}:8686"
is_enabled readarr    && echo -e "${BOLD}Readarr:${NC}        http://${SERVER_IP}:8787"
is_enabled whisparr   && echo -e "${BOLD}Whisparr:${NC}       http://${SERVER_IP}:6969"
is_enabled seerr && echo -e "${BOLD}Seerr:${NC}     http://${SERVER_IP}:5055"
is_enabled arr-dashboard && echo -e "${BOLD}ARR Dashboard:${NC}  http://${SERVER_IP}:3050"
is_enabled bazarr     && echo -e "${BOLD}Bazarr:${NC}         http://${SERVER_IP}:6767"
is_enabled qbittorrent && echo -e "${BOLD}qBittorrent:${NC}    http://${SERVER_IP}:8088  (VPN only)"
is_enabled sabnzbd    && echo -e "${BOLD}SABnzbd:${NC}        http://${SERVER_IP}:8085"
is_enabled npm        && echo -e "${BOLD}Nginx Proxy Mgr:${NC} http://${SERVER_IP}:81"
echo ""
if [[ "$SKIP_SAMBA" == false ]]; then
  echo -e "${BOLD}SMB Shares (\\\\${SERVER_IP}\\):${NC} Media, Downloads, Shared — user ${SMB_USER}"
  echo ""
fi
echo -e "${BOLD}Files:${NC} ${INSTALL_ROOT}/docker-compose.yml, ${INSTALL_ROOT}/.env"
echo -e "${BOLD}Useful:${NC} docker compose -f ${INSTALL_ROOT}/docker-compose.yml ps"
echo ""
echo -e "${YELLOW}NEXT STEPS:${NC}"
echo -e "  1. Open Portainer at http://${SERVER_IP}:9000 and create an admin password"
echo -e "  2. Open Prowlarr and add your indexers"
echo -e "  3. Connect Prowlarr to Sonarr/Radarr/Lidarr via their settings"
echo -e "  4. Point each *arr app's download client at qBittorrent/SABnzbd"
echo -e "  5. Log out and back in as ${STACK_USER} for the docker group to take effect"
if is_enabled qbittorrent; then
  echo ""
  echo -e "${YELLOW}VPN NOTE:${NC} qBittorrent will NOT connect if the Gluetun VPN is down."
  echo -e "  Check: docker logs gluetun"
fi
if [[ "$SKIP_TAILSCALE" == false && "$TAILSCALE_JOINED" == false ]]; then
  echo ""
  echo -e "${YELLOW}TAILSCALE:${NC} installed but not joined yet — run 'sudo tailscale up'"
fi
if [[ "$SKIP_NTFY" == false ]]; then
  echo ""
  echo -e "${YELLOW}ALERTS:${NC} install the ntfy app (or visit https://ntfy.sh/${NTFY_TOPIC}"
  echo -e "  in a browser) and subscribe to topic: ${BOLD}${NTFY_TOPIC}${NC}"
  echo -e "  You'll get a push notification (with sound) whenever an app goes down"
  echo -e "  or comes back up. Anyone who knows this exact topic name can also see"
  echo -e "  these alerts — keep it private the same as a password."
fi
echo -e "${YELLOW}ONBOARDING:${NC} to make plain http://${SERVER_IP} (port 80) forward to the"
echo -e "  Dashboard instead of showing NPM's default page, log into NPM at :81 and set"
echo -e "  Settings > Default Site > Custom HTML to a small JS redirect to :8090 — see"
echo -e "  README.md for the exact snippet."
echo ""
