#!/bin/bash
# Export hide-sensitive config + download binary .backup from the connected MikroTik.
#
# Usage:
#   bash deployment/scripts/mikrotik-pull-backup.sh [MIKROTIK_HOST]
#   npm run mikrotik:pull-backup
#
# Writes under deployment/mikrotik/backup/<YYYY-MM-DD>/live/ unless --gold:
#   live/  = lab dump (vouchers/users as on the box)
#   --gold = starting template for that date: <MODEL>-config.backup at folder root

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/_mikrotik-ssh-bootstrap.sh"

BACKUP_ROOT="${REPO_ROOT}/deployment/mikrotik/backup"
DATE_STAMP="$(date +%Y-%m-%d)"
ROUTER_BACKUP_NAME="lokalfi-${DATE_STAMP}"

usage() {
  printf "%s\n" "${BLUE}[INFO] Usage: $0 [--gold] [MIKROTIK_HOST]${NC}"
  printf "%s\n" "  Default: deployment/mikrotik/backup/${DATE_STAMP}/live/<MODEL>-config.backup"
  printf "%s\n" "  --gold:  deployment/mikrotik/backup/${DATE_STAMP}/<MODEL>-config.backup (starting template)"
}

HOST_OVERRIDE=""
GOLD=false
while [ $# -gt 0 ]; do
  case "$1" in
    --gold)
      GOLD=true
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

if [ "$GOLD" = true ]; then
  DATE_DIR="${BACKUP_ROOT}/${DATE_STAMP}"
else
  DATE_DIR="${BACKUP_ROOT}/${DATE_STAMP}/live"
fi

_run_scp_from_router() {
  local remote_name="$1"
  local local_path="$2"
  local legacy_flag=()
  if [ "${MIKROTIK_SCP_USE_LEGACY:-}" = "true" ]; then
    legacy_flag=(-O)
  fi
  if [ -n "${MIKROTIK_PASSWORD:-}" ] && command -v sshpass >/dev/null 2>&1; then
    SSHPASS="$MIKROTIK_PASSWORD" sshpass -e scp "${legacy_flag[@]}" -P "$PORT" \
      "${SSH_CONN_OPTS[@]}" \
      "${USER_NAME}@${HOST}:${remote_name}" "$local_path"
  else
    scp "${legacy_flag[@]}" -P "$PORT" \
      "${SSH_CONN_OPTS[@]}" \
      "${USER_NAME}@${HOST}:${remote_name}" "$local_path"
  fi
}

mikrotik_ssh_bootstrap "${HOST_OVERRIDE}"

MODEL="$(_run_ssh '/system routerboard print' 2>/dev/null | sed -n 's/^[[:space:]]*model:[[:space:]]*//p' | head -1 | tr -d '\r' | xargs || true)"
case "$MODEL" in
  E50UG | e50ug)
    MODEL_LABEL="E50UG"
    ;;
  RB750Gr3 | rb750gr3)
    MODEL_LABEL="RB750Gr3"
    ;;
  "")
    MODEL_LABEL="UNKNOWN"
    printf "%s\n" "${YELLOW}[WARNING] Could not read routerboard model; file prefix UNKNOWN.${NC}"
    ;;
  *)
    MODEL_LABEL="$MODEL"
    ;;
esac

mkdir -p "$DATE_DIR"
EXPORT_FILE="${DATE_DIR}/${MODEL_LABEL}-live-export.rsc"
BINARY_LOCAL="${DATE_DIR}/${MODEL_LABEL}-config.backup"
REMOTE_BINARY="${ROUTER_BACKUP_NAME}.backup"

printf "%s\n" "${BLUE}[INFO] Model: ${MODEL_LABEL} → ${DATE_DIR}/${NC}"
printf "%s\n" "${BLUE}[INFO] Exporting hide-sensitive config to ${EXPORT_FILE} ...${NC}"
_run_ssh '/export compact hide-sensitive' > "$EXPORT_FILE"

printf "%s\n" "${BLUE}[INFO] Saving binary backup on router: ${ROUTER_BACKUP_NAME} ...${NC}"
_run_ssh "/system backup save name=${ROUTER_BACKUP_NAME}" || {
  printf "%s\n" "${RED}[ERROR] Binary backup save failed (check free disk on router).${NC}"
  exit 1
}

printf "%s\n" "${BLUE}[INFO] Downloading ${REMOTE_BINARY} → ${BINARY_LOCAL} ...${NC}"
_run_scp_from_router "$REMOTE_BINARY" "$BINARY_LOCAL"

if [ ! -f "$BINARY_LOCAL" ] || [ ! -s "$BINARY_LOCAL" ]; then
  printf "%s\n" "${RED}[ERROR] Download failed or empty file.${NC}"
  exit 1
fi

printf "%s\n" "${GREEN}[SUCCESS] ${BINARY_LOCAL} ($(wc -c < "$BINARY_LOCAL") bytes)${NC}"
printf "%s\n" "${GREEN}[SUCCESS] ${EXPORT_FILE} ($(wc -l < "$EXPORT_FILE") lines)${NC}"
printf "%s\n" "${BLUE}[INFO] Restore on same model: upload ${MODEL_LABEL}-config.backup → /system backup load name=${MODEL_LABEL}-config${NC}"
