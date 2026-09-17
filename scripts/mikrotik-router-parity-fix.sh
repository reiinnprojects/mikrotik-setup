#!/bin/bash
# Unified Lokalfi MikroTik fixes after backup restore / new hardware (WAN + RouterOS 7 device-mode).
# Combines MIKROTIK-WAN-INTERNET-FIX.md and ENABLE-MIKROTIK-HOTSPOT-DEVICE-MODE.md flows.
#
# Default (no mode flags): WAN parity fix, then device-mode hotspot=yes CLI (physical confirm required).
#
# Usage:
#   bash deployment/scripts/mikrotik-router-parity-fix.sh [MIKROTIK_HOST]
#   npm run mikrotik:router-parity-fix
#
# Mode flags (combinable where noted):
#   --wan-only           Only DHCP/NAT/WAN steps (no device-mode update).
#   --device-mode-only   Only print status + optional hotspot=yes update (--verify-only skips update).
#   --verify-only        Print /system/device-mode/print and /ip hotspot print only (no WAN, no update).
#   --dry-run            Print planned actions; no SSH (WAN + device-mode text only).
#
# With --wan-only --verify-only: run WAN fixes, then print device-mode + hotspot status.
#
# Environment (same as upload-hotspot-to-mikrotik.sh):
#   MIKROTIK_HOST, MIKROTIK_USER, MIKROTIK_PORT, MIKROTIK_PASSWORD
#   deployment/docker/.env: NEXT_PUBLIC_MIKROTIK_* / MIKROTIK_PASSWORD
#
# WAN parity matches RB750Gr3 manual checklist (default ether1-ISP):
#   - Rename ether1 -> ether1-ISP + ISP comment (fallback set comment if already renamed)
#   - DHCP: remove invalid; move clients from ether1 -> ether1-ISP; normalize ISP comment + flags; add if missing
#   - NAT: remove stale comments + invalid masquerade + WAN masquerade (lokalfi-script); add clean WAN + hotspot masquerade if missing
#
#   MIKROTIK_WAN_INTERFACE       Override WAN name for DHCP/NAT only (default: ether1-ISP). If not ether1-ISP, skips ethernet rename block.
#   MIKROTIK_WAN_SKIP_ETHER_COMMENT=true   Skip WAN ethernet comment lines
#   MIKROTIK_WAN_ETHER_COMMENT    Override comment text (default: internet provider (starlink,...))
#   MIKROTIK_AUTO_INSTALL_SSHPASS, MIKROTIK_SSH_NO_MUX
#
# See deployment/docs/TROUBLESHOOTING.md (#mikrotik-cli-helper-scripts).

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/_mikrotik-ssh-bootstrap.sh"

usage() {
  printf "%s\n" "${BLUE}[INFO] Usage: $0 [options] [MIKROTIK_HOST]${NC}"
  printf "%s\n" ""
  printf "%s\n" "  Default: WAN fix + device-mode update hotspot=yes (confirm physically on router)."
  printf "%s\n" "  --wan-only           WAN/DHCP/NAT steps only."
  printf "%s\n" "  --device-mode-only   Device-mode / hotspot CLI only (use --verify-only to skip update)."
  printf "%s\n" "  --verify-only        Print checklist audits (device-mode, hotspot, then WAN step 4 read-only if WAN fixes did not run this invocation)."
  printf "%s\n" "  --wan-only --verify-only   WAN fix, then print device-mode + hotspot."
  printf "%s\n" "  --dry-run            Describe actions; no SSH."
  printf "%s\n" ""
  printf "%s\n" "  Default WAN parity = RB750Gr3 checklist (ether1 -> ether1-ISP, DHCP ISP, NAT cleanup)."
  printf "%s\n" "  Override WAN only if needed: MIKROTIK_WAN_INTERFACE=ether5 (skips ether1 rename block)."
  printf "%s\n" "  npm: mikrotik:router-parity-fix | mikrotik:fix-wan-internet | mikrotik:enable-hotspot-device-mode"
}

HOST_OVERRIDE=""
DRY_RUN=false

WAN_FLAG=false
DM_FLAG=false
VERIFY_ONLY=false

while [ $# -gt 0 ]; do
  case "$1" in
    --wan-only)
      WAN_FLAG=true
      shift
      ;;
    --device-mode-only)
      DM_FLAG=true
      shift
      ;;
    --verify-only)
      VERIFY_ONLY=true
      shift
      ;;
    --dry-run)
      DRY_RUN=true
      shift
      ;;
    -h | --help)
      usage
      exit 0
      ;;
    -*)
      printf "%s\n" "${RED}[ERROR] Unknown option: $1${NC}"
      usage
      exit 1
      ;;
    *)
      HOST_OVERRIDE="$1"
      shift
      break
      ;;
  esac
done

if [ $# -gt 0 ]; then
  printf "%s\n" "${YELLOW}[WARNING] Ignoring extra arguments: $*${NC}"
fi

ANY_MODE=false
if [ "$WAN_FLAG" = true ] || [ "$DM_FLAG" = true ] || [ "$VERIFY_ONLY" = true ]; then
  ANY_MODE=true
fi

DO_WAN=false
DO_DM_UPDATE=false
DO_DM_PRINT=false

if [ "$ANY_MODE" = false ]; then
  DO_WAN=true
  DO_DM_UPDATE=true
  DO_DM_PRINT=true
else
  [ "$WAN_FLAG" = true ] && DO_WAN=true
  if [ "$DM_FLAG" = true ]; then
    DO_DM_UPDATE=true
    DO_DM_PRINT=true
  fi
  if [ "$VERIFY_ONLY" = true ]; then
    DO_DM_PRINT=true
    DO_DM_UPDATE=false
    [ "$WAN_FLAG" = false ] && DO_WAN=false
  fi
fi

WAN_TARGET="${MIKROTIK_WAN_INTERFACE:-ether1-ISP}"

if [[ ! "$WAN_TARGET" =~ ^[a-zA-Z0-9_-]+$ ]]; then
  printf "%s\n" "${RED}[ERROR] Invalid WAN interface name: ${WAN_TARGET}${NC}"
  exit 1
fi

run_wan_block() {
  DEFAULT_WAN_COMMENT='internet provider (starlink,globe,smart,gomo)'
  WAN_ETH_COMMENT="${MIKROTIK_WAN_ETHER_COMMENT:-$DEFAULT_WAN_COMMENT}"

  # --- Step 1: RB750Gr3 WAN ethernet (same as paste checklist) ---
  if [ "$WAN_TARGET" = "ether1-ISP" ]; then
    printf "%s\n" "${BLUE}[INFO] [1/4] WAN ethernet -> ether1-ISP + comment (RB750 checklist) ...${NC}"
    if [ "${MIKROTIK_WAN_SKIP_ETHER_COMMENT:-false}" = "true" ]; then
      _run_ssh '/interface ethernet set [find default-name=ether1] name=ether1-ISP' || true
    else
      _run_ssh '/interface ethernet set [find default-name=ether1] name=ether1-ISP comment="'"${WAN_ETH_COMMENT}"'"' || true
      _run_ssh '/interface ethernet set ether1-ISP comment="'"${WAN_ETH_COMMENT}"'"' || true
    fi
  else
    printf "%s\n" "${YELLOW}[WARNING] WAN_TARGET=${WAN_TARGET} (not ether1-ISP): skipping ether1 rename / ether1-ISP comment steps.${NC}"
  fi

  printf "%s\n" "${BLUE}[INFO] [2/4] DHCP cleanup + align WAN (${WAN_TARGET}) ...${NC}"
  _run_ssh '/ip dhcp-client remove [find invalid=yes]' || true

  printf "%s\n" "${BLUE}[INFO] [3/4] NAT cleanup (stale comments + invalid masquerade + lokalfi-script WAN rule) ...${NC}"
  printf "%s\n" "${BLUE}[INFO]       (Manual checklist used remove numbers=0; we use remove [find invalid=yes] for invalid rows.)${NC}"
  _run_ssh '/ip firewall nat remove [find comment~"ether1-ISP not ready"]' || true
  _run_ssh '/ip firewall nat remove [find comment~"WAN masquerade (lokalfi-script)"]' || true
  _run_ssh '/ip firewall nat remove [find chain=srcnat action=masquerade invalid=yes]' || true

  # --- Steps 2–3 continued: DHCP normalize + NAT ensure (single RouterOS script) ---
  printf "%s\n" "${BLUE}[INFO] Applying DHCP/NAT batch for WAN=${WAN_TARGET} ...${NC}"

  ROS_BATCH=""
  if [ "$WAN_TARGET" = "ether1-ISP" ]; then
    ROS_BATCH=":local wan \"ether1-ISP\"; \
:foreach id in=[/ip dhcp-client find where interface=ether1] do={ \
/ip dhcp-client set \$id interface=\$wan comment=\"ISP\" disabled=no add-default-route=yes use-peer-dns=yes use-peer-ntp=yes \
}; \
"
  fi

  ROS_BATCH+=":local wan \"${WAN_TARGET}\"; \
:foreach id in=[/ip dhcp-client find where interface=\$wan] do={ \
/ip dhcp-client set \$id comment=\"ISP\" disabled=no add-default-route=yes use-peer-dns=yes use-peer-ntp=yes \
}; \
:if ([:len [/ip dhcp-client find where interface=\$wan]] = 0) do={ \
/ip dhcp-client add interface=\$wan comment=\"ISP\" disabled=no add-default-route=yes use-peer-dns=yes use-peer-ntp=yes \
}; \
:if ([:len [/ip firewall nat find where chain=srcnat action=masquerade out-interface=\$wan]] = 0) do={ \
/ip firewall nat add chain=srcnat action=masquerade out-interface=\$wan \
}; \
:if ([:len [/ip firewall nat find where chain=srcnat action=masquerade src-address=10.0.0.0/24]] = 0) do={ \
/ip firewall nat add chain=srcnat action=masquerade src-address=10.0.0.0/24 comment=\"masquerade hotspot network\" \
}"

  _run_ssh "$ROS_BATCH"

  printf "%s\n" "${BLUE}[INFO] [4/4] Quick checks (route + ping) ...${NC}"
  _run_ssh '/ip dhcp-client print'
  _run_ssh '/ip firewall nat print where chain=srcnat'
  _run_ssh '/ip route print where dst-address=0.0.0.0/0'
  _run_ssh '/ping 8.8.8.8 count=3'
}

# RB750 checklist "step 4" read-only (no config changes). Skipped when --wan-only ran first this invocation (WAN block already prints these).
run_rb750_verify_readonly_block() {
  printf "%s\n" "${BLUE}[INFO] RB750 checklist verification (read-only, step 4 + WAN naming) ...${NC}"
  _run_ssh '/interface ethernet print where name~"ether1"'
  _run_ssh '/ip dhcp-client print'
  _run_ssh '/ip firewall nat print where chain=srcnat'
  _run_ssh '/ip route print where dst-address=0.0.0.0/0'
  _run_ssh '/ping 8.8.8.8 count=3'
}

run_dm_print_block() {
  printf "%s\n" "${BLUE}[INFO] Current device-mode:${NC}"
  _run_ssh '/system/device-mode/print'
  printf "%s\n" "${BLUE}[INFO] Current hotspot summary:${NC}"
  _run_ssh '/ip hotspot print'
}

run_dm_apply_block() {
  local dm
  dm="$(_run_ssh '/system/device-mode/print' 2>/dev/null || true)"
  if printf '%s\n' "$dm" | grep -qiE 'hotspot:[[:space:]]*yes'; then
    printf "%s\n" "${GREEN}[SUCCESS] Device-mode hotspot is already yes — skip update (no reset countdown).${NC}"
    return 0
  fi
  printf "%s\n" "${YELLOW}[WARNING] Scheduling hotspot=yes in device-mode.${NC}"
  printf "%s\n" "${YELLOW}[WARNING] Confirm on the router: briefly tap reset (do not hold) OR power-cycle.${NC}"
  printf "%s\n" "${YELLOW}[WARNING] This cannot be completed over SSH alone.${NC}"
  printf "%s\n" "${BLUE}[INFO] Applying /system/device-mode/update hotspot=yes ...${NC}"
  _run_ssh '/system/device-mode/update hotspot=yes'
  printf "%s\n" "${GREEN}[SUCCESS] Device-mode CLI update sent.${NC}"
  printf "%s\n" "${BLUE}[INFO] After reboot, run device-mode --verify-only for ${HOST}${NC}"
}

if [ "$DRY_RUN" = true ]; then
  printf "%s\n" "${YELLOW}[INFO] Dry run: no SSH.${NC}"
  printf "%s\n" "${BLUE}[INFO] WAN target: ${WAN_TARGET} (default ether1-ISP = full RB750 checklist)${NC}"
  if [ "$DO_WAN" = true ]; then
    printf "%s\n" "${BLUE}[INFO] [WAN] Step 1: ether1 -> ether1-ISP + ISP comment (fallback line if already renamed)${NC}"
    printf "%s\n" "${BLUE}[INFO] [WAN] Step 2: dhcp-client remove invalid; move ether1 -> ether1-ISP; set ISP + flags; add if missing${NC}"
    printf "%s\n" "${BLUE}[INFO] [WAN] Step 3: NAT remove (ether1-ISP not ready, WAN lokalfi-script, invalid=yes masquerade); add WAN + hotspot if missing${NC}"
    printf "%s\n" "${BLUE}[INFO] [WAN] Step 4: dhcp-client print, nat print srcnat, route, ping 8.8.8.8${NC}"
    if [ "$WAN_TARGET" != "ether1-ISP" ]; then
      printf "%s\n" "${YELLOW}[WARNING] Non-default WAN_TARGET: skips ethernet rename block.${NC}"
    fi
  fi
  if [ "$DO_DM_PRINT" = true ]; then
    printf "%s\n" "${BLUE}[INFO] [DM] Print device-mode + hotspot${NC}"
  fi
  if [ "$VERIFY_ONLY" = true ] && [ "$DO_WAN" = false ]; then
    printf "%s\n" "${BLUE}[INFO] [--verify-only] RB750 step 4: ethernet ether1*, dhcp-client, nat srcnat, default route, ping${NC}"
  fi
  if [ "$DO_DM_UPDATE" = true ]; then
    printf "%s\n" "${BLUE}[INFO] [DM] Run /system/device-mode/update hotspot=yes${NC}"
  fi
  exit 0
fi

mikrotik_ssh_bootstrap "${HOST_OVERRIDE}"

if [ "$DO_WAN" = true ]; then
  run_wan_block
fi

if [ "$DO_DM_PRINT" = true ]; then
  run_dm_print_block
fi

# Pure --verify-only (and similar paths without WAN this run): include checklist step 4 audits like paste checklist §4.
if [ "$VERIFY_ONLY" = true ] && [ "$DO_WAN" = false ]; then
  run_rb750_verify_readonly_block
fi

if [ "$DO_DM_UPDATE" = true ]; then
  run_dm_apply_block
elif [ "$VERIFY_ONLY" = true ]; then
  printf "%s\n" "${GREEN}[SUCCESS] Verify-only complete.${NC}"
elif [ "$DO_WAN" = true ] && [ "$DO_DM_PRINT" = false ]; then
  printf "%s\n" "${GREEN}[SUCCESS] WAN-only steps completed.${NC}"
else
  printf "%s\n" "${GREEN}[SUCCESS] Parity fix script completed.${NC}"
fi

if [ "$DO_WAN" = true ]; then
  printf "%s\n" "${BLUE}[INFO] If LAN still fails, check /ip firewall filter chain=forward (see TROUBLESHOOTING).${NC}"
fi
