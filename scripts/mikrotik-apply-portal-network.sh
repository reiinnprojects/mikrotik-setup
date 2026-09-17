#!/bin/bash
# Idempotent Lokalfi split-DNS + hotspot walled garden (portal + Tier A/C on-prem ports).
#
# Usage:
#   bash deployment/scripts/mikrotik-apply-portal-network.sh [options] [MIKROTIK_HOST]
#   npm run mikrotik:apply-portal-network
#
# Environment:
#   NUC_LAN_IP=192.168.10.220
#   STARBOOKS_IP=192.168.10.230
#   MIKROTIK_* — same as other mikrotik scripts (see _mikrotik-ssh-bootstrap.sh)

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/_mikrotik-ssh-bootstrap.sh"

NUC_LAN_IP="${NUC_LAN_IP:-192.168.10.220}"
STARBOOKS_IP="${STARBOOKS_IP:-192.168.10.230}"
DRY_RUN=false
HOST_OVERRIDE=""

usage() {
  printf "%s\n" "${BLUE}[INFO] Usage: $0 [--dry-run] [MIKROTIK_HOST]${NC}"
  printf "%s\n" "  NUC_LAN_IP=${NUC_LAN_IP} STARBOOKS_IP=${STARBOOKS_IP}"
}

while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run)
      DRY_RUN=true
      shift
      ;;
    -h | --help)
      usage
      exit 0
      ;;
    *)
      HOST_OVERRIDE="$1"
      shift
      ;;
  esac
done

# Escape for RouterOS double-quoted strings
ros_escape() {
  printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'
}

NUC_ESC="$(ros_escape "$NUC_LAN_IP")"
STAR_ESC="$(ros_escape "$STARBOOKS_IP")"

run_ros() {
  local cmd="$1"
  if [ "$DRY_RUN" = true ]; then
    printf "%s\n" "${BLUE}[DRY-RUN] ${cmd}${NC}"
    return 0
  fi
  _run_ssh "$cmd"
}

ensure_dns_static() {
  local name="$1"
  local addr="$2"
  local comment="$3"
  local name_esc comment_esc addr_esc
  name_esc="$(ros_escape "$name")"
  comment_esc="$(ros_escape "$comment")"
  addr_esc="$(ros_escape "$addr")"
  run_ros ":if ([:len [/ip dns static find where name=\"${name_esc}\"]] = 0) do={ /ip dns static add address=\"${addr_esc}\" comment=\"${comment_esc}\" name=\"${name_esc}\" type=A } else={ /ip dns static set [find where name=\"${name_esc}\"] address=\"${addr_esc}\" comment=\"${comment_esc}\" }"
}

ensure_wg_host() {
  local comment="$1"
  local host="$2"
  local ports="$3"
  local comment_esc host_esc ports_esc add_cmd
  comment_esc="$(ros_escape "$comment")"
  host_esc="$(ros_escape "$host")"
  if [ -n "$ports" ]; then
    ports_esc="$(ros_escape "$ports")"
    add_cmd="/ip hotspot walled-garden add comment=\"${comment_esc}\" dst-host=\"${host_esc}\" dst-port=${ports_esc} server=hotspot1"
  else
    add_cmd="/ip hotspot walled-garden add comment=\"${comment_esc}\" dst-host=\"${host_esc}\""
  fi
  run_ros ":if ([:len [/ip hotspot walled-garden find where comment=\"${comment_esc}\"]] = 0) do={ ${add_cmd} }"
}

ensure_wg_ip() {
  local comment="$1"
  local addr="$2"
  local port_spec="$3"
  local comment_esc addr_esc port_spec_esc
  comment_esc="$(ros_escape "$comment")"
  addr_esc="$(ros_escape "$addr")"
  port_spec_esc="$(ros_escape "$port_spec")"
  if [ -n "$port_spec" ]; then
    run_ros ":if ([:len [/ip hotspot walled-garden ip find where comment=\"${comment_esc}\"]] = 0) do={ /ip hotspot walled-garden ip add action=accept comment=\"${comment_esc}\" dst-address=\"${addr_esc}\" dst-port=${port_spec_esc} protocol=tcp server=hotspot1 }"
  else
    run_ros ":if ([:len [/ip hotspot walled-garden ip find where comment=\"${comment_esc}\"]] = 0) do={ /ip hotspot walled-garden ip add action=accept comment=\"${comment_esc}\" dst-address=\"${addr_esc}\" server=hotspot1 }"
  fi
}

mikrotik_ssh_bootstrap "${HOST_OVERRIDE}"

printf "%s\n" "${BLUE}[INFO] Applying Lokalfi portal network (NUC=${NUC_LAN_IP}, Starbooks=${STARBOOKS_IP}) ...${NC}"

ensure_dns_static "app.lokalfi.net" "$NUC_LAN_IP" "NUC app host (static IP)"

ensure_wg_host "***access lokalfi.net" "app.lokalfi.net" "80,443"
ensure_wg_host "***access on premises apps 1/2 [wg]" "app.lokalfi.net" "8080-8089"
ensure_wg_host "***access on premises apps 2/2 [wg]" "app.lokalfi.net" "8090-8099"
ensure_wg_host "***taranood: CNA Cloudfront" "d2e1asnsl7br7b.cloudfront.net" ""

ensure_wg_ip "***access lokalfi.net 1/2 [wg ip]" "$NUC_LAN_IP" "80"
ensure_wg_ip "***access lokalfi.net 2/2 [wg ip]" "$NUC_LAN_IP" "443"
ensure_wg_ip "***access on-premises-apps 1/2 [wg ip]" "$NUC_LAN_IP" "8080-8089"
ensure_wg_ip "***access on-premises-apps 2/2 [wg ip]" "$NUC_LAN_IP" "8090-8099"
ensure_wg_ip "***access STARBOOKS [wg ip]" "$STARBOOKS_IP" ""

if [ "$DRY_RUN" = true ]; then
  printf "%s\n" "${BLUE}[INFO] Dry run complete.${NC}"
  exit 0
fi

printf "%s\n" "${BLUE}[INFO] Current walled-garden (hostname):${NC}"
_run_ssh '/ip hotspot walled-garden print where disabled=no'
printf "%s\n" "${BLUE}[INFO] Current walled-garden ip:${NC}"
_run_ssh '/ip hotspot walled-garden ip print'
printf "%s\n" "${GREEN}[SUCCESS] Portal network rules applied (existing comments left unchanged).${NC}"
