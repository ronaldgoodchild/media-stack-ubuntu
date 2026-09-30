#!/bin/bash
# Writes dashboard/stats.json — polled by dashboard/index.html to render the
# Storage gauges, the Memory gauge, and each app card's status dot. Run on a
# timer (mediastack-stats.timer); not meant to be run by hand, though it's
# harmless to. Needs docker CLI access (the stack user is in the docker
# group) and read access to /proc — both already true for whoever installed
# the stack.
set -euo pipefail

INSTALL_ROOT="${1:-/opt/mediastack}"
OUT="${INSTALL_ROOT}/dashboard/stats.json"
TMP="${OUT}.tmp"

# --- Disks: every real mounted filesystem (skip tmpfs/overlay/loop/snap noise) ---
disks_json=""
first=true
while read -r target size used pcent; do
  [[ -z "$target" ]] && continue
  pcent="${pcent%\%}"
  label="$target"
  [[ "$target" == "/" ]] && label="System"
  [[ "$target" == "/mnt/media" ]] && label="Media"
  $first || disks_json+=","
  first=false
  disks_json+=$(printf '{"mount":"%s","label":"%s","size":%s,"used":%s,"pcent":%s}' \
    "$target" "$label" "$size" "$used" "$pcent")
done < <(df -B1 --output=target,size,used,pcent -x tmpfs -x devtmpfs -x squashfs -x overlay 2>/dev/null | tail -n +2)

# --- Memory: "used" counts what's actually unavailable, not raw+cache ---
read -r mem_total mem_avail < <(free -b | awk '/^Mem:/ {print $2, $7}')
mem_used=$(( mem_total - mem_avail ))
mem_pcent=$(( mem_total > 0 ? mem_used * 100 / mem_total : 0 ))

# --- Services: status, live full container ID (for the Portainer deep-link)
# and a live per-app stat ("3 queued - 5 missing", "idle", "2 streaming")
# for every app whose API we know how to read. Also fires the ntfy.sh
# down/up alerts below. All of this moved into one Python script
# (tools/collect-services.py) rather than bash — juggling `docker compose
# ps`/`docker inspect`/`curl` output through `while read` loops kept hitting
# real bash pitfalls (a subprocess inside the loop stealing stdin from the
# next `read`; IFS=$'\t' still collapsing consecutive empty fields) that
# just don't exist in Python. ---
services_json=$(python3 "$(dirname "$0")/collect-services.py" "$INSTALL_ROOT")

# --- Activity: merged recent grabs/imports across Sonarr/Radarr/Lidarr/
# Readarr/Whisparr, newest first — see collect-activity.py. ---
activity_json=$(python3 "$(dirname "$0")/collect-activity.py")

# --- Tailscale: connected state + current join link (if still pending).
# This service runs as root (no `sudo` needed) so `tailscale status` works
# directly even before any non-root user has been granted access. ---
ts_connected=false
ts_url=""
if command -v tailscale >/dev/null 2>&1; then
  ts_status=$(tailscale status 2>&1 || true)
  if echo "$ts_status" | grep -q "^Logged out"; then
    ts_url=$(echo "$ts_status" | grep -oE "https://login\.tailscale\.com/a/[A-Za-z0-9]+" || true)
  elif [[ -n "$ts_status" ]]; then
    ts_connected=true
  fi
fi

NTFY_TOPIC=$(grep -m1 "^NTFY_TOPIC=" "${INSTALL_ROOT}/.env" 2>/dev/null | cut -d= -f2-)

{
  printf '{"disks":[%s],"memory":{"total":%s,"used":%s,"pcent":%s},"services":%s,"activity":%s,"tailscale":{"connected":%s,"loginUrl":%s},"ntfyTopic":%s}' \
    "$disks_json" "$mem_total" "$mem_used" "$mem_pcent" "$services_json" "$activity_json" \
    "$ts_connected" "$([ -n "$ts_url" ] && printf '"%s"' "$ts_url" || echo null)" \
    "$([ -n "$NTFY_TOPIC" ] && printf '"%s"' "$NTFY_TOPIC" || echo null)"
} > "$TMP"
mv "$TMP" "$OUT"
