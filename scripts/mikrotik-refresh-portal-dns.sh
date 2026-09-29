#!/bin/bash
# Refresh Tanay-style lokalfi.net dynamic DNS on the router (hsprof1 + hotspot1 bounce).
#
# Usage:
#   npm run mikrotik:refresh-portal-dns
#   bash deployment/scripts/mikrotik-refresh-portal-dns.sh [MIKROTIK_HOST]

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/_mikrotik-ssh-bootstrap.sh"
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/_mikrotik-portal-dns-heal.sh"

DRY_RUN=false
HOST_OVERRIDE=""

while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run)
      DRY_RUN=true
      shift
      ;;
    *)
      HOST_OVERRIDE="$1"
      shift
      ;;
  esac
done

run_ros() {
  local cmd="$1"
  if [ "$DRY_RUN" = true ]; then
    printf "%s\n" "${BLUE}[DRY-RUN] ${cmd}${NC}"
    return 0
  fi
  _run_ssh "$cmd"
}

mikrotik_ssh_bootstrap "${HOST_OVERRIDE}"
refresh_hotspot_portal_dns
verify_hotspot_portal_dns
