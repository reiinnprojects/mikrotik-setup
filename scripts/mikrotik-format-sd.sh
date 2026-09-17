#!/bin/bash
# Format one removable RouterOS disk as exFAT. RB750 SD/USB only — never internal flash.
#
# Usage:
#   npm run mikrotik:format-sd
#   bash deployment/scripts/mikrotik-format-sd.sh [--yes] [--slot sd2] [--probe] [MIKROTIK_HOST]
#
# Zero slots: tell them to insert a card. Two or more: abort (do not guess).

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/_mikrotik-ssh-bootstrap.sh"

usage() {
  printf "%s\n" "${BLUE}[INFO] Usage: $0 [--yes] [--slot SLOT] [--probe] [MIKROTIK_HOST]${NC}"
  printf "%s\n" "  Formats exactly one removable slot as exFAT on the router."
  printf "%s\n" "  --probe  print unique parent slots and exit (0 = one, 2 = none, 3 = many)"
}

YES=false
PROBE=false
FORCE_SLOT=""
HOST_OVERRIDE=""

while [ $# -gt 0 ]; do
  case "$1" in
    --yes)
      YES=true
      shift
      ;;
    --slot)
      FORCE_SLOT="${2:-}"
      shift 2
      ;;
    --probe)
      PROBE=true
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
      ;;
  esac
done

_parent_slot() {
  local s="$1"
  s="$(printf '%s' "$s" | tr '[:upper:]' '[:lower:]')"
  s="${s%%-part*}"
  printf '%s' "$s"
}

_list_parent_slots() {
  local out
  # Hardware slots with a card (empty=no). Ignore unused sd1/sd2/usb1 names.
  out="$(_run_ssh ':foreach id in=[/disk find where type=hardware empty=no] do={ :put [/disk get $id slot] }' 2>/dev/null || true)"
  out="$(printf '%s\n' "$out" | tr -d '\r' | awk 'tolower($0) ~ /^(sd|usb|disk)[0-9]+$/ { print tolower($0) }')"
  if [ -z "$out" ]; then
    return 0
  fi
  printf '%s\n' "$out" | LC_ALL=C sort -u
}

mikrotik_ssh_bootstrap "${HOST_OVERRIDE}"

RB_PRINT="$(_run_ssh '/system routerboard print' 2>/dev/null || true)"
MODEL="$(printf '%s\n' "$RB_PRINT" | sed -n 's/^[[:space:]]*model:[[:space:]]*//p' | head -1 | tr -d '\r' | xargs || true)"
case "$MODEL" in
  E50UG | e50ug)
    printf "%s\n" "${RED}[ERROR] E50UG uses internal flash. Do not format an SD/USB on this model.${NC}"
    exit 1
    ;;
esac

mapfile -t SLOTS < <(_list_parent_slots)

if [ -n "$FORCE_SLOT" ]; then
  SLOT="$(_parent_slot "$FORCE_SLOT")"
else
  SLOT=""
  if [ "${#SLOTS[@]}" -eq 1 ]; then
    SLOT="${SLOTS[0]}"
  fi
fi

if [ "$PROBE" = true ]; then
  if [ "${#SLOTS[@]}" -eq 0 ]; then
    printf "%s\n" "${YELLOW}[WARNING] No removable storage. Insert an SD card and rerun.${NC}"
    exit 2
  fi
  printf '%s\n' "${SLOTS[@]}"
  if [ "${#SLOTS[@]}" -gt 1 ] && [ -z "$FORCE_SLOT" ]; then
    printf "%s\n" "${YELLOW}[WARNING] Multiple removable slots. Pass --slot <name> (do not guess).${NC}" >&2
    exit 3
  fi
  exit 0
fi

if [ "${#SLOTS[@]}" -eq 0 ] && [ -z "$FORCE_SLOT" ]; then
  printf "%s\n" "${RED}[ERROR] No SD/USB found. Insert a card and rerun.${NC}"
  exit 2
fi
if [ "${#SLOTS[@]}" -gt 1 ] && [ -z "$FORCE_SLOT" ]; then
  printf "%s\n" "${RED}[ERROR] Multiple removable slots:${NC}"
  printf '  %s\n' "${SLOTS[@]}"
  printf "%s\n" "${BLUE}[INFO] Pass --slot sd2 (or the slot you want). Do not format the wrong USB.${NC}"
  exit 3
fi
if [ -z "$SLOT" ]; then
  printf "%s\n" "${RED}[ERROR] No slot to format.${NC}"
  exit 1
fi

printf "%s\n" "${YELLOW}[WARNING] This erases all files on ${SLOT} (exFAT).${NC}"
if [ "$YES" != true ] && [ -t 0 ]; then
  printf "%s" "${BLUE}[INFO] Type yes to format ${SLOT}: ${NC}"
  read -r ans || ans=""
  if [ "$ans" != "yes" ]; then
    printf "%s\n" "${YELLOW}[WARNING] Aborted.${NC}"
    exit 1
  fi
fi

printf "%s\n" "${BLUE}[INFO] /disk format ${SLOT} file-system=exfat mbr-partition-table=yes${NC}"
_run_ssh "/disk format ${SLOT} file-system=exfat mbr-partition-table=yes"
printf "%s\n" "${BLUE}[INFO] Waiting until ${SLOT} is mounted (format can take a minute) ...${NC}"
mounted=false
for _i in $(seq 1 40); do
  sleep 3
  det="$(_run_ssh "/disk print detail where parent=${SLOT}" 2>/dev/null || true)"
  if printf '%s\n' "$det" | grep -qE '^[ ]*[0-9]+[[:space:]]+.*M'; then
    mounted=true
    break
  fi
  if printf '%s\n' "$det" | grep -qi 'fs=exfat' && printf '%s\n' "$det" | grep -qv 'partition-size=0'; then
    if printf '%s\n' "$det" | grep -qE 'partition-size=[1-9]'; then
      mounted=true
      break
    fi
  fi
  printf "%s\n" "${BLUE}[INFO] Still waiting (${_i}/40) ...${NC}"
done
_run_ssh '/disk print' || true
if [ "$mounted" != true ]; then
  printf "%s\n" "${RED}[ERROR] ${SLOT} did not mount after format (card I/O or format stuck).${NC}"
  exit 2
fi
printf "%s\n" "${GREEN}[SUCCESS] Formatted ${SLOT} as exFAT and mounted.${NC}"
