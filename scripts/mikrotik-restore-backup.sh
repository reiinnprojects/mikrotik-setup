#!/bin/bash
# Upload a RouterOS .backup and /system backup load (same model only).
#
# Usage:
#   bash deployment/scripts/mikrotik-restore-backup.sh --file PATH [MIKROTIK_HOST]
#   npm run mikrotik:restore-backup -- --file /path/to/E50UG-config.backup
#
# ROS 7 needs password="" on unencrypted backups. Load reboots the router.
# Gold is RouterOS 7.20.1. Lab serial HJC0A5MY028 is refused unless --force.

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/_mikrotik-ssh-bootstrap.sh"

LAB_SERIAL="HJC0A5MY028"
GOLD_ROS="7.20.1"

usage() {
  printf "%s\n" "${BLUE}[INFO] Usage: $0 --file PATH [--force] [--wait] [MIKROTIK_HOST]${NC}"
  printf "%s\n" "  Restores a same-model .backup. Never cross E50UG and RB750Gr3."
  printf "%s\n" "  --force  allow lab serial ${LAB_SERIAL}"
  printf "%s\n" "  --wait   poll SSH after load (admin/lokalfi.net on 192.168.10.1)"
}

BACKUP_FILE=""
FORCE=false
WAIT_REBOOT=false
HOST_OVERRIDE=""

while [ $# -gt 0 ]; do
  case "$1" in
    --file)
      BACKUP_FILE="${2:-}"
      shift 2
      ;;
    --force)
      FORCE=true
      shift
      ;;
    --wait)
      WAIT_REBOOT=true
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

if [ -z "$BACKUP_FILE" ]; then
  printf "%s\n" "${RED}[ERROR] --file PATH is required.${NC}"
  usage
  exit 1
fi
if [ ! -f "$BACKUP_FILE" ] || [ ! -s "$BACKUP_FILE" ]; then
  printf "%s\n" "${RED}[ERROR] Backup file missing or empty: ${BACKUP_FILE}${NC}"
  exit 1
fi

BASE="$(basename "$BACKUP_FILE")"
case "$BASE" in
  *E50UG*) EXPECT_MODEL="E50UG" ;;
  *RB750Gr3* | *RB750GR3* | *rb750gr3*) EXPECT_MODEL="RB750Gr3" ;;
  *)
    printf "%s\n" "${RED}[ERROR] Filename must include E50UG or RB750Gr3: ${BASE}${NC}"
    exit 1
    ;;
esac

REMOTE_NAME="lokalfi-restore"
REMOTE_FILE="${REMOTE_NAME}.backup"

_version_lt() {
  # true if $1 < $2 (dotted numeric)
  [ "$(printf '%s\n' "$1" "$2" | sort -V | head -n 1)" = "$1" ] && [ "$1" != "$2" ]
}

mikrotik_ssh_bootstrap "${HOST_OVERRIDE}"

RB_PRINT="$(_run_ssh '/system routerboard print' 2>/dev/null || true)"
MODEL="$(printf '%s\n' "$RB_PRINT" | sed -n 's/^[[:space:]]*model:[[:space:]]*//p' | head -1 | tr -d '\r' | xargs || true)"
SERIAL="$(printf '%s\n' "$RB_PRINT" | sed -n 's/^[[:space:]]*serial-number:[[:space:]]*//p' | head -1 | tr -d '\r' | xargs || true)"
if [ -z "$SERIAL" ]; then
  SERIAL="$(printf '%s\n' "$RB_PRINT" | sed -n 's/^[[:space:]]*serial number:[[:space:]]*//p' | head -1 | tr -d '\r' | xargs || true)"
fi

case "$MODEL" in
  E50UG | e50ug) MODEL_LABEL="E50UG" ;;
  RB750Gr3 | rb750gr3) MODEL_LABEL="RB750Gr3" ;;
  *)
    printf "%s\n" "${RED}[ERROR] Unsupported or unread model '${MODEL}'. Expected E50UG or RB750Gr3.${NC}"
    exit 1
    ;;
esac

if [ "$MODEL_LABEL" != "$EXPECT_MODEL" ]; then
  printf "%s\n" "${RED}[ERROR] Backup is ${EXPECT_MODEL} but router is ${MODEL_LABEL}. Never cross-restore.${NC}"
  exit 1
fi

if [ "$SERIAL" = "$LAB_SERIAL" ] && [ "$FORCE" != true ]; then
  printf "%s\n" "${RED}[ERROR] Serial ${LAB_SERIAL} is the lab E50 (test vouchers). Pass --force to restore anyway.${NC}"
  exit 1
fi

RES_PRINT="$(_run_ssh '/system resource print' 2>/dev/null || true)"
ROS_VER="$(printf '%s\n' "$RES_PRINT" | sed -n 's/^[[:space:]]*version:[[:space:]]*//p' | awk '{print $1}' | tr -d '\r')"
printf "%s\n" "${BLUE}[INFO] Model ${MODEL_LABEL} serial ${SERIAL:-?} RouterOS ${ROS_VER:-?} (gold ${GOLD_ROS})${NC}"

if [ -z "$ROS_VER" ]; then
  printf "%s\n" "${YELLOW}[WARNING] Could not read RouterOS version.${NC}"
elif [ "${ROS_VER%%.*}" != "7" ]; then
  printf "%s\n" "${RED}[ERROR] Gold backup is RouterOS 7 (${GOLD_ROS}). This box reports ${ROS_VER}.${NC}"
  exit 1
else
  ROS_MINOR="${ROS_VER#7.}"
  ROS_MINOR="${ROS_MINOR%%.*}"
  if [ "$ROS_MINOR" -lt 12 ] 2>/dev/null; then
    printf "%s\n" "${RED}[ERROR] RouterOS ${ROS_VER} is too old for this gold backup. Upgrade toward ${GOLD_ROS} first.${NC}"
    exit 1
  fi
  if _version_lt "$ROS_VER" "$GOLD_ROS"; then
    printf "%s\n" "${YELLOW}[WARNING] RouterOS ${ROS_VER} is behind gold ${GOLD_ROS}. Restore may still work on the same model.${NC}"
  fi
fi

printf "%s\n" "${BLUE}[INFO] Uploading ${BACKUP_FILE} → ${REMOTE_FILE} ...${NC}"
legacy_flag=()
if [ "${MIKROTIK_SCP_USE_LEGACY:-}" = "true" ]; then
  legacy_flag=(-O)
fi
if [ -n "${MIKROTIK_PASSWORD:-}" ] && command -v sshpass >/dev/null 2>&1; then
  SSHPASS="$MIKROTIK_PASSWORD" sshpass -e scp "${legacy_flag[@]}" -P "$PORT" \
    "${SSH_CONN_OPTS[@]}" \
    "$BACKUP_FILE" "${USER_NAME}@${HOST}:${REMOTE_FILE}"
else
  scp "${legacy_flag[@]}" -P "$PORT" \
    "${SSH_CONN_OPTS[@]}" \
    "$BACKUP_FILE" "${USER_NAME}@${HOST}:${REMOTE_FILE}"
fi

printf "%s\n" "${BLUE}[INFO] /system backup load name=${REMOTE_NAME} password=\"\" (router will reboot)${NC}"
set +e
LOAD_OUT="$(_run_ssh "/system backup load name=${REMOTE_NAME} password=\"\"" 2>&1)"
LOAD_RC=$?
set -e
if [ -n "$LOAD_OUT" ]; then
  printf "%s\n" "$LOAD_OUT"
fi
if [ $LOAD_RC -ne 0 ]; then
  printf "%s\n" "${YELLOW}[WARNING] SSH exited ${LOAD_RC} after load (normal if the router already rebooted).${NC}"
fi

printf "%s\n" "${GREEN}[SUCCESS] Load sent. After reboot: admin / lokalfi.net at 192.168.10.1 on ether2-LAN.${NC}"

if [ "$WAIT_REBOOT" != true ]; then
  exit 0
fi

WAIT_HOST="${MIKROTIK_WAIT_HOST:-192.168.10.1}"
WAIT_USER="${MIKROTIK_WAIT_USER:-admin}"
WAIT_PASS="${MIKROTIK_WAIT_PASSWORD:-lokalfi.net}"
printf "%s\n" "${BLUE}[INFO] Waiting for SSH on ${WAIT_HOST} ...${NC}"
_close_ssh_mux 2>/dev/null || true
if command -v ssh-keygen >/dev/null 2>&1; then
  ssh-keygen -R "$WAIT_HOST" >/dev/null 2>&1 || true
fi
ok=false
for _i in $(seq 1 36); do
  sleep 5
  if [ -n "$WAIT_PASS" ] && command -v sshpass >/dev/null 2>&1; then
    SSHPASS="$WAIT_PASS" sshpass -e ssh -p "$PORT" -o StrictHostKeyChecking=accept-new -o ConnectTimeout=5 \
      "${WAIT_USER}@${WAIT_HOST}" '/system identity print' >/dev/null 2>&1 && ok=true && break
  else
    ssh -p "$PORT" -o StrictHostKeyChecking=accept-new -o ConnectTimeout=5 \
      "${WAIT_USER}@${WAIT_HOST}" '/system identity print' >/dev/null 2>&1 && ok=true && break
  fi
done
if [ "$ok" != true ]; then
  printf "%s\n" "${RED}[ERROR] No SSH on ${WAIT_HOST} after ~3 min. Check cable (ether2-LAN) and subnet 192.168.10.0/24.${NC}"
  exit 1
fi
printf "%s\n" "${GREEN}[SUCCESS] SSH is up on ${WAIT_HOST}${NC}"
