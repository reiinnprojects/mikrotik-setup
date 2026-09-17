#!/bin/bash
# Upload deployment/mikrotik/flash/hotspot to MikroTik RouterOS Files as flash/hotspot via SCP (SFTP).
# Same layout as Winbox Files → flash/hotspot/ (see deployment/docs/TROUBLESHOOTING.md).
#
# Usage:
#   npm run mikrotik:upload-hotspot
#   ./upload-hotspot-to-mikrotik.sh [MIKROTIK_HOST]
#
# Environment:
#   Router IP: first CLI argument > MIKROTIK_HOST > NEXT_PUBLIC_MIKROTIK_MANAGEMENT_IP in deployment/docker/.env > 192.168.10.1
#   MIKROTIK_USER      SSH user (default: admin)
#   MIKROTIK_PORT      SSH port (default: 22)
#   MIKROTIK_PASSWORD  Optional; uses sshpass when set. If unset, loaded from deployment/docker/.env:
#                      MIKROTIK_PASSWORD or NEXT_PUBLIC_MIKROTIK_PASSWORD (requires sshpass).
#   MIKROTIK_SCP_USE_LEGACY  Set to "true" to pass -O to scp (older RouterOS / OpenSSH quirks)
#   MIKROTIK_HOTSPOT_SKIP_REMOTE_DELETE  Set to "true" to skip SSH wipe before upload (merge-only)
#   MIKROTIK_UPLOAD_BULK      Set to "true" for one recursive scp (no per-file progress; fastest).
#   MIKROTIK_UPLOAD_NO_MUX    Set to "true" to disable SSH multiplexing (per-file mode uses mux by default).
#   MIKROTIK_UPLOAD_PROGRESS_MULTILINE  Set to "true" for one log line per file (default: one updating bar when stdout is a TTY).
#   MIKROTIK_UPLOAD_PROGRESS_ASCII  Set to "true" for =/- progress bar instead of Unicode █░ (UTF-8 default).
#   MIKROTIK_ROUTER_FILES_DISK Force upload disk root: flash (internal) or removable volume (disk1, usb1, sd2-part1, …).
#                      When unset, the script probes the router: no removable media → flash/hotspot/;
#                      SD/USB present → interactive choice (TTY) or flash when non-interactive.
#   MIKROTIK_UPLOAD_DISK_NONINTERACTIVE  Set to "true" to skip the disk menu and use flash when removable media exists.
#                      (Use MIKROTIK_ROUTER_FILES_DISK=disk1 to target external storage without prompting.)
#                      SFTP cannot mkdir volume roots (flash, disk1) — only paths below them are created.
#   MIKROTIK_UPLOAD_SKIP_SFTP_MKDIRS  Set to "true" to skip SFTP mkdir prelude (may break per-file scp on RouterOS).
#   MIKROTIK_AUTO_INSTALL_SSHPASS  Set to "false" to skip trying to install sshpass when missing (default: try on macOS/Linux/Git Bash).
#
# Before SSH/SCP, runs ssh-keygen -R for this host (and [host]:port if PORT≠22) so stale keys after
# router resets do not block the upload. Uses StrictHostKeyChecking=accept-new on connect afterward.

set -e

GREEN=$(printf '\033[0;32m')
YELLOW=$(printf '\033[1;33m')
BLUE=$(printf '\033[0;34m')
RED=$(printf '\033[0;31m')
NC=$(printf '\033[0m') # No Color

usage() {
  printf "%s\n" "${BLUE}[INFO] Usage: $0 [MIKROTIK_HOST]${NC}"
  printf "%s\n" "  Default router IP is 192.168.10.1 (or NEXT_PUBLIC_MIKROTIK_MANAGEMENT_IP in deployment/docker/.env)."
  printf "%s\n" "  Uploads deployment/mikrotik/flash/... to the router (Files → flash/hotspot/ or disk1/flash/hotspot/, recursive)."
  printf "%s\n" "  Detects removable storage (disk1, usb1, …); prompts when present. Clears stale SSH keys, wipes remote hotspot tree, SCP uploads."
  printf "%s\n" "  Force target: MIKROTIK_ROUTER_FILES_DISK=disk1  (internal default: flash)"
  printf "%s\n" "  Default upload uses one updating progress line (Unicode █░ bar); MIKROTIK_UPLOAD_PROGRESS_ASCII=true uses =/-; MIKROTIK_UPLOAD_PROGRESS_MULTILINE=true logs each file."
  printf "%s\n" ""
  printf "%s\n" "${BLUE}[INFO] Examples:${NC}"
  printf "%s\n" "  npm run mikrotik:upload-hotspot"
  printf "%s\n" "  $0"
  printf "%s\n" "  $0 192.168.88.1   # optional: override IP"
  printf "%s\n" "  MIKROTIK_PASSWORD=secret $0   # needs sshpass for password auth"
  printf "%s\n" "  # With NEXT_PUBLIC_MIKROTIK_PASSWORD (or MIKROTIK_PASSWORD) in deployment/docker/.env and sshpass installed, no typing needed."
  printf "%s\n" ""
  printf "%s\n" "  Password from .env uses sshpass; missing sshpass triggers an automatic install attempt unless MIKROTIK_AUTO_INSTALL_SSHPASS=false."
}

if [ "${1:-}" = "-h" ] || [ "${1:-}" = "--help" ]; then
  usage
  exit 0
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [ -n "${MIKROTIK_PORTAL_ROOT:-}" ]; then
  REPO_ROOT="${MIKROTIK_PORTAL_ROOT}"
else
  REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
fi
SOURCE_PARENT="$REPO_ROOT/deployment/mikrotik/flash"
SOURCE_DIR="$SOURCE_PARENT/hotspot"
# Upload the whole local `flash` tree to remote `:/` so RouterOS SFTP gets flash/hotspot/ (avoids
# realpath failures when copying only `hotspot` into /flash/ on some RouterOS builds).
MIKROTIK_SCP_FROM_DIR="$REPO_ROOT/deployment/mikrotik"
# Set by _resolve_upload_disk_target after probing the router (default internal: flash/hotspot).
REMOTE_HOTSPOT_PATH=""
ROUTER_FILES_DISK=""
SCP_REMOTE_PREFIX=""
DOCKER_ENV_FILE="$REPO_ROOT/deployment/docker/.env"

USER_NAME="${MIKROTIK_USER:-admin}"
PORT="${MIKROTIK_PORT:-22}"

# Strip optional surrounding quotes and CR (Windows line endings).
_trim_env_value() {
  local v="$1"
  v="${v//$'\r'/}"
  if [[ "$v" =~ ^\".*\"$ ]]; then v="${v#\"}"; v="${v%\"}"; fi
  if [[ "$v" =~ ^\'.*\'$ ]]; then v="${v#\'}"; v="${v%\'}"; fi
  printf '%s' "$v"
}

# Attempt package-manager install of sshpass (subshell: does not trip set -e on failed commands).
_try_auto_install_sshpass() (
  set +e
  if command -v sshpass >/dev/null 2>&1; then
    exit 0
  fi

  printf "%s\n" "${BLUE}[INFO] sshpass not found; attempting install (set MIKROTIK_AUTO_INSTALL_SSHPASS=false to skip) ...${NC}"

  uname_s="$(uname -s 2>/dev/null || printf unknown)"

  case "$uname_s" in
    Darwin)
      if ! command -v brew >/dev/null 2>&1; then
        printf "%s\n" "${YELLOW}[WARNING] Homebrew not found; install https://brew.sh then brew install sshpass.${NC}"
        exit 1
      fi
      if brew install sshpass >/dev/null 2>&1; then
        :
      elif brew tap esolitos/ipa >/dev/null 2>&1 && brew install sshpass >/dev/null 2>&1; then
        :
      elif brew install hudochenkov/sshpass/sshpass >/dev/null 2>&1; then
        :
      else
        brew install sshpass 2>&1 || true
      fi
      ;;
    Linux)
      if command -v apt-get >/dev/null 2>&1; then
        sudo apt-get update -qq && sudo apt-get install -y sshpass
      elif command -v dnf >/dev/null 2>&1; then
        sudo dnf install -y sshpass
      elif command -v yum >/dev/null 2>&1; then
        sudo yum install -y sshpass
      elif command -v pacman >/dev/null 2>&1; then
        sudo pacman -S --noconfirm sshpass
      elif command -v zypper >/dev/null 2>&1; then
        sudo zypper install -y sshpass
      elif command -v apk >/dev/null 2>&1; then
        sudo apk add sshpass
      elif command -v nix-env >/dev/null 2>&1; then
        nix-env -iA nixpkgs.sshpass
      else
        printf "%s\n" "${YELLOW}[WARNING] No supported package manager found for Linux (apt, dnf, yum, pacman, zypper, apk, nix).${NC}"
      fi
      ;;
    MINGW*|MSYS*|CYGWIN*)
      if command -v pacman >/dev/null 2>&1; then
        pacman -Sy --noconfirm sshpass 2>/dev/null || pacman -S --noconfirm sshpass 2>/dev/null || true
      fi
      if ! command -v sshpass >/dev/null 2>&1 && command -v choco >/dev/null 2>&1; then
        choco install sshpass -y
      fi
      if ! command -v sshpass >/dev/null 2>&1 && command -v scoop >/dev/null 2>&1; then
        scoop install sshpass
      fi
      if ! command -v sshpass >/dev/null 2>&1; then
        printf "%s\n" "${YELLOW}[WARNING] Windows: install MSYS2/Git Bash pacman, Chocolatey, or Scoop sshpass; or use WSL (apt).${NC}"
      fi
      ;;
    *)
      printf "%s\n" "${YELLOW}[WARNING] Auto-install not mapped for OS: ${uname_s}${NC}"
      ;;
  esac

  if command -v sshpass >/dev/null 2>&1; then
    printf "%s\n" "${GREEN}[SUCCESS] sshpass is now available.${NC}"
    exit 0
  fi
  exit 1
)

# Load MikroTik-related keys from deployment/docker/.env (single pass).
PASSWORD_FROM_DOCKER_ENV=false
mi_private=""
mi_public=""
mi_mgmt_ip=""
if [ -f "$DOCKER_ENV_FILE" ]; then
  while IFS= read -r line || [ -n "$line" ]; do
    [[ "$line" =~ ^[[:space:]]*# ]] && continue
    [[ -z "${line// /}" ]] && continue
    if [[ "$line" =~ ^MIKROTIK_PASSWORD= ]]; then
      mi_private="$(_trim_env_value "${line#MIKROTIK_PASSWORD=}")"
    elif [[ "$line" =~ ^NEXT_PUBLIC_MIKROTIK_PASSWORD= ]]; then
      mi_public="$(_trim_env_value "${line#NEXT_PUBLIC_MIKROTIK_PASSWORD=}")"
    elif [[ "$line" =~ ^NEXT_PUBLIC_MIKROTIK_MANAGEMENT_IP= ]]; then
      mi_mgmt_ip="$(_trim_env_value "${line#NEXT_PUBLIC_MIKROTIK_MANAGEMENT_IP=}")"
    fi
  done < "$DOCKER_ENV_FILE"
fi

if [ -z "${MIKROTIK_PASSWORD:-}" ]; then
  if [ -n "$mi_private" ]; then
    MIKROTIK_PASSWORD="$mi_private"
    PASSWORD_FROM_DOCKER_ENV=true
  elif [ -n "$mi_public" ]; then
    MIKROTIK_PASSWORD="$mi_public"
    PASSWORD_FROM_DOCKER_ENV=true
  fi
  export MIKROTIK_PASSWORD
fi

DEFAULT_MIKROTIK_IP="192.168.10.1"
if [ -n "${1:-}" ]; then
  HOST="$1"
elif [ -n "${MIKROTIK_HOST:-}" ]; then
  HOST="$MIKROTIK_HOST"
elif [ -n "$mi_mgmt_ip" ]; then
  HOST="$mi_mgmt_ip"
else
  HOST="$DEFAULT_MIKROTIK_IP"
fi

if [ ! -d "$SOURCE_DIR" ]; then
  printf "%s\n" "${RED}[ERROR] Missing hotspot folder: ${SOURCE_DIR}${NC}"
  exit 1
fi

if [ -n "${MIKROTIK_PASSWORD:-}" ] && ! command -v sshpass >/dev/null 2>&1; then
  if [ "${MIKROTIK_AUTO_INSTALL_SSHPASS:-true}" != "false" ]; then
    _try_auto_install_sshpass || true
  fi
fi

if [ -n "${MIKROTIK_PASSWORD:-}" ] && ! command -v sshpass >/dev/null 2>&1; then
  if [ "$PASSWORD_FROM_DOCKER_ENV" = true ]; then
    printf "%s\n" "${RED}[ERROR] Loaded MikroTik password from ${DOCKER_ENV_FILE} but sshpass is still not available after auto-install (set MIKROTIK_AUTO_INSTALL_SSHPASS=false to suppress tries).${NC}"
    printf "%s\n" "${BLUE}[INFO] Install sshpass to use the saved password non-interactively (macOS: brew install sshpass; Debian/Ubuntu: sudo apt install sshpass).${NC}"
    printf "%s\n" "${BLUE}[INFO] Or remove/unset the password in .env and enter it when SSH/scp prompts.${NC}"
    exit 1
  fi
  printf "%s\n" "${YELLOW}[WARNING] MIKROTIK_PASSWORD is set but sshpass was not found; SSH and scp will prompt for a password.${NC}"
  printf "%s\n" "${BLUE}[INFO] Install sshpass for non-interactive uploads, or use SSH key auth.${NC}"
fi

if [ "$PASSWORD_FROM_DOCKER_ENV" = true ]; then
  printf "%s\n" "${BLUE}[INFO] Using MikroTik password from ${DOCKER_ENV_FILE}${NC}"
fi

printf "%s\n" "${BLUE}[INFO] Router ${HOST} (${USER_NAME}, port ${PORT})${NC}"

# Shared SSH options (multiplexing speeds up many per-file scp calls).
# OpenSSH enforces a short ControlPath (~104 chars). macOS TMPDIR under /var/folders/... exceeds it;
# /tmp/lmf-%C stays short (%C = hash of local host, remote host, port, user — unique per target).
SSH_MUX_CONTROL_PATH="/tmp/lmf-%C"
SSH_CONN_OPTS=( -o StrictHostKeyChecking=accept-new )
if [ "${MIKROTIK_UPLOAD_NO_MUX:-}" != "true" ]; then
  SSH_CONN_OPTS+=( -o ControlMaster=auto -o "ControlPath=${SSH_MUX_CONTROL_PATH}" -o ControlPersist=120 )
fi

_close_ssh_mux() {
  if [ "${MIKROTIK_UPLOAD_NO_MUX:-}" = "true" ]; then
    return 0
  fi
  ssh -p "$PORT" -o "ControlPath=${SSH_MUX_CONTROL_PATH}" -O exit "${USER_NAME}@${HOST}" 2>/dev/null || true
}
trap _close_ssh_mux EXIT INT TERM

_clear_stale_known_host_for_router() {
  if ! command -v ssh-keygen >/dev/null 2>&1; then
    printf "%s\n" "${YELLOW}[WARNING] ssh-keygen not in PATH; skipping known_hosts refresh.${NC}"
    return 0
  fi
  printf "%s\n" "${BLUE}[INFO] Refreshing SSH known_hosts for ${HOST} (remove stale key after reset/reinstall) ...${NC}"
  ssh-keygen -R "$HOST" >/dev/null 2>&1 || true
  if [ "$PORT" != "22" ]; then
    ssh-keygen -R "[${HOST}]:${PORT}" >/dev/null 2>&1 || true
  fi
}

_clear_stale_known_host_for_router

# SSH into RouterOS CLI (same auth as scp). Used to wipe remote hotspot tree before upload.
_run_ssh() {
  local remote_cmd="$1"
  if [ -n "${MIKROTIK_PASSWORD:-}" ] && command -v sshpass >/dev/null 2>&1; then
    SSHPASS="$MIKROTIK_PASSWORD" sshpass -e ssh -p "$PORT" \
      "${SSH_CONN_OPTS[@]}" \
      "${USER_NAME}@${HOST}" "$remote_cmd"
  else
    ssh -p "$PORT" \
      "${SSH_CONN_OPTS[@]}" \
      "${USER_NAME}@${HOST}" "$remote_cmd"
  fi
}

# Normalize disk slot name from env or user input (flash, disk1, usb1, …).
_normalize_router_files_disk() {
  local disk="$1"
  disk="${disk#"${disk%%[![:space:]]*}"}"
  disk="${disk%"${disk##*[![:space:]]}"}"
  disk="${disk#/}"
  disk="${disk%/}"
  disk=$(printf '%s' "$disk" | tr '[:upper:]' '[:lower:]')
  printf '%s' "$disk"
}

# flash/hotspot vs disk1/flash/hotspot — drives wipe patterns, SFTP mkdir, and scp targets.
_set_remote_paths_from_disk() {
  local disk
  disk="$(_normalize_router_files_disk "$1")"
  if [ -z "$disk" ]; then
    disk="flash"
  fi
  ROUTER_FILES_DISK="$disk"
  if [ "$disk" = "flash" ]; then
    REMOTE_HOTSPOT_PATH="flash/hotspot"
    SCP_REMOTE_PREFIX=""
  else
    REMOTE_HOTSPOT_PATH="${disk}/flash/hotspot"
    SCP_REMOTE_PREFIX="$disk"
  fi
}

# RouterOS Files volume names we treat as removable (not internal flash).
# Examples: disk1, usb1, sd2, sd2-part1 (SD slot + MBR partition — common on RouterBOARD).
_router_removable_volume_name_from_file_line() {
  printf '%s\n' "$1" | awk '
    /^[[:space:]]*[0-9]+[[:space:]]/ {
      name = tolower($2)
      type = tolower($3)
      if (type != "disk" && type != "partition") {
        exit
      }
      if (name == "" || name == "flash") {
        exit
      }
      if (name ~ /^(disk|usb|sd)[0-9]+(-part[0-9]+)?$/) {
        print name
      }
    }'
}

# Prefer partitioned mount (sd2-part1) when /disk print shows parent slot sd2.
_router_partition_volume_for_slot() {
  local parent="$1"
  local file_out line part
  parent="$(_normalize_router_files_disk "$parent")"
  file_out=$(_run_ssh '/file print' 2>/dev/null) || file_out=""
  if [ -z "$file_out" ]; then
    return 1
  fi
  part=$(printf '%s\n' "$file_out" | awk -v p="$parent" '
    /^[[:space:]]*[0-9]+[[:space:]]/ {
      name = tolower($2)
      type = tolower($3)
      if (type != "disk" && type != "partition") next
      if (name ~ ("^" p "-part[0-9]+$")) print name
    }' | LC_ALL=C sort | head -n 1)
  if [ -n "$part" ]; then
    printf '%s' "$part"
    return 0
  fi
  return 1
}

# Removable volumes: /file print first (sd2-part1, disk1, usb1), then /disk print with FS check.
_list_router_removable_disks() {
  local file_out disk_out line slot part
  local -a found=()

  file_out=$(_run_ssh '/file print' 2>/dev/null) || file_out=""
  if [ "${MIKROTIK_UPLOAD_DISK_DEBUG:-}" = "true" ] && [ -n "$file_out" ]; then
    printf "%s\n" "${BLUE}[DEBUG] /file print:${NC}" >&2
    printf '%s\n' "$file_out" >&2
  fi

  if [ -n "$file_out" ]; then
    while IFS= read -r line; do
      slot=$(_router_removable_volume_name_from_file_line "$line")
      if [ -n "$slot" ]; then
        found+=("$slot")
      fi
    done <<EOF
$file_out
EOF
  fi

  disk_out=$(_run_ssh '/disk print' 2>/dev/null) || disk_out=""
  if [ "${MIKROTIK_UPLOAD_DISK_DEBUG:-}" = "true" ] && [ -n "$disk_out" ]; then
    printf "%s\n" "${BLUE}[DEBUG] /disk print:${NC}" >&2
    printf '%s\n' "$disk_out" >&2
  fi

  if [ -n "$disk_out" ]; then
    while IFS= read -r line; do
      slot=$(printf '%s\n' "$line" | awk '
        /^[[:space:]]*[0-9]+[[:space:]]/ {
          line_lc = tolower($0)
          if (line_lc !~ /(ext[2-4]|fat16|fat32|exfat|btrfs|xfs|iso9660|ntfs)/) {
            next
          }
          for (i = 2; i <= 5; i++) {
            if ($i ~ /^(disk|usb|sd)[0-9]+$/) {
              print tolower($i)
              exit
            }
          }
        }')
      if [ -z "$slot" ] || [ "$slot" = "flash" ]; then
        continue
      fi
      if part=$(_router_partition_volume_for_slot "$slot" 2>/dev/null); then
        slot="$part"
      fi
      found+=("$slot")
    done <<EOF
$disk_out
EOF
  fi

  if [ "${#found[@]}" -eq 0 ]; then
    return 0
  fi

  printf '%s\n' "${found[@]}" | LC_ALL=C sort -u
}

# Remote scp path for a repo-relative path (e.g. flash/hotspot/login.html).
_remote_scp_dest_for_rel() {
  local rel="$1"
  if [ -n "$SCP_REMOTE_PREFIX" ]; then
    printf '%s' "${USER_NAME}@${HOST}:/${SCP_REMOTE_PREFIX}/${rel}"
  else
    printf '%s' "${USER_NAME}@${HOST}:/${rel}"
  fi
}

_resolve_upload_disk_target() {
  local forced extra_disks disk choice menu_idx d disk_count

  if [ -n "${MIKROTIK_ROUTER_FILES_DISK:-}" ]; then
    forced="$(_normalize_router_files_disk "${MIKROTIK_ROUTER_FILES_DISK}")"
    _set_remote_paths_from_disk "$forced"
    printf "%s\n" "${BLUE}[INFO] Upload target (from MIKROTIK_ROUTER_FILES_DISK): Files → ${REMOTE_HOTSPOT_PATH}/${NC}"
    return 0
  fi

  extra_disks=$(_list_router_removable_disks || true)
  disk_count=0
  if [ -n "$extra_disks" ]; then
    disk_count=$(printf '%s\n' "$extra_disks" | grep -c . || true)
  fi

  if [ "${MIKROTIK_REQUIRE_REMOVABLE:-}" = "true" ]; then
    if [ "$disk_count" -eq 0 ]; then
      printf "%s\n" "${RED}[ERROR] No SD/USB found. Insert a card and rerun (this model does not use internal flash).${NC}"
      exit 1
    fi
    if [ "$disk_count" -gt 1 ]; then
      printf "%s\n" "${RED}[ERROR] Multiple removable volumes. Set MIKROTIK_ROUTER_FILES_DISK to one slot.${NC}"
      printf '%s\n' "$extra_disks" | sed 's/^/  /'
      exit 1
    fi
    disk="$(printf '%s\n' "$extra_disks" | head -n 1)"
    _set_remote_paths_from_disk "$disk"
    printf "%s\n" "${BLUE}[INFO] Single removable volume — using Files → ${REMOTE_HOTSPOT_PATH}/${NC}"
    return 0
  fi

  if [ -z "$extra_disks" ]; then
    _set_remote_paths_from_disk "flash"
    printf "%s\n" "${BLUE}[INFO] No removable storage detected on router — using internal Files → ${REMOTE_HOTSPOT_PATH}/${NC}"
    return 0
  fi

  printf "%s\n" "${BLUE}[INFO] Removable storage on router:${NC}"
  while IFS= read -r disk; do
    [ -n "$disk" ] && printf "%s\n" "  - ${disk}  (upload path: ${disk}/flash/hotspot/)"
  done <<EOF
$extra_disks
EOF

  if [ ! -t 0 ] || [ "${MIKROTIK_UPLOAD_DISK_NONINTERACTIVE:-}" = "true" ]; then
    _set_remote_paths_from_disk "flash"
    printf "%s\n" "${YELLOW}[WARNING] Non-interactive session — using internal ${REMOTE_HOTSPOT_PATH}/. Set MIKROTIK_ROUTER_FILES_DISK=<slot> to upload to removable media.${NC}"
    return 0
  fi

  printf "%s\n" ""
  printf "%s\n" "${BLUE}[INFO] Choose upload destination:${NC}"
  printf "%s\n" "  1) flash/hotspot/  (internal storage — default)"
  menu_idx=2
  while IFS= read -r disk; do
    [ -z "$disk" ] && continue
    printf "%s\n" "  ${menu_idx}) ${disk}/flash/hotspot/  (SD/USB)"
    menu_idx=$((menu_idx + 1))
  done <<EOF
$extra_disks
EOF

  while true; do
    printf "%s" "${BLUE}[INFO] Enter choice [1]: ${NC}"
    IFS= read -r choice || choice=""
    choice="${choice:-1}"
    if [ "$choice" = "1" ]; then
      _set_remote_paths_from_disk "flash"
      printf "%s\n" "${BLUE}[INFO] Using internal Files → ${REMOTE_HOTSPOT_PATH}/${NC}"
      return 0
    fi
    menu_idx=2
    while IFS= read -r disk; do
      [ -z "$disk" ] && continue
      if [ "$choice" = "$menu_idx" ]; then
        _set_remote_paths_from_disk "$disk"
        printf "%s\n" "${BLUE}[INFO] Using removable Files → ${REMOTE_HOTSPOT_PATH}/${NC}"
        return 0
      fi
      menu_idx=$((menu_idx + 1))
    done <<EOF
$extra_disks
EOF
    printf "%s\n" "${YELLOW}[WARNING] Invalid choice. Enter 1 or a number from the list.${NC}"
  done
}

_resolve_upload_disk_target

_clear_remote_hotspot_dir() {
  if [ "${MIKROTIK_HOTSPOT_SKIP_REMOTE_DELETE:-false}" = "true" ]; then
    printf "%s\n" "${YELLOW}[WARNING] Skipping remote ${REMOTE_HOTSPOT_PATH}/ delete (MIKROTIK_HOTSPOT_SKIP_REMOTE_DELETE=true). Upload merges only.${NC}"
    return 0
  fi
  printf "%s\n" "${BLUE}[INFO] Clearing remote Files ${REMOTE_HOTSPOT_PATH}/ via SSH (removes MikroTik defaults such as alogin.html and stale files not in this repo) ...${NC}"
  # RouterOS expects `/file remove [find where ...]` (not `[/file find ...]`). Failures are non-fatal.
  _run_ssh "/file remove [find where name~\"${REMOTE_HOTSPOT_PATH}/\"]" || true
  _run_ssh "/file remove [find where name=\"${REMOTE_HOTSPOT_PATH}\"]" || true
}

_clear_remote_hotspot_dir

_run_scp() {
  local legacy_flag=()
  if [ "${MIKROTIK_SCP_USE_LEGACY:-}" = "true" ]; then
    legacy_flag=( -O )
  fi
  if [ -n "${MIKROTIK_PASSWORD:-}" ] && command -v sshpass >/dev/null 2>&1; then
    SSHPASS="$MIKROTIK_PASSWORD" sshpass -e scp "${legacy_flag[@]}" -P "$PORT" \
      "${SSH_CONN_OPTS[@]}" \
      "$@"
  else
    scp "${legacy_flag[@]}" -P "$PORT" \
      "${SSH_CONN_OPTS[@]}" \
      "$@"
  fi
}

# RouterOS SFTP often rejects single-file scp unless parent folders exist; recursive scp creates them.
_run_sftp_batch() {
  local batch="$1"
  if [ ! -s "$batch" ]; then
    return 0
  fi
  if ! command -v sftp >/dev/null 2>&1; then
    printf "%s\n" "${RED}[ERROR] sftp not in PATH; cannot prepare remote folders for per-file upload.${NC}"
    printf "%s\n" "${BLUE}[INFO] Use MIKROTIK_UPLOAD_BULK=true or install OpenSSH SFTP client.${NC}"
    return 1
  fi
  if [ -n "${MIKROTIK_PASSWORD:-}" ] && command -v sshpass >/dev/null 2>&1; then
    SSHPASS="$MIKROTIK_PASSWORD" sshpass -e sftp -b "$batch" -P "$PORT" \
      "${SSH_CONN_OPTS[@]}" \
      "${USER_NAME}@${HOST}"
  else
    sftp -b "$batch" -P "$PORT" \
      "${SSH_CONN_OPTS[@]}" \
      "${USER_NAME}@${HOST}"
  fi
}

# Emit flash, flash/hotspot, … for dirpath "flash/hotspot/__experiment__/default" (RouterOS needs each level).
_append_all_prefix_paths_of_dir() {
  local dirpath="$1"
  local out="$2"
  local acc="" rest="$dirpath" seg

  [ -z "$dirpath" ] || [ "$dirpath" = "." ] && return 0

  while [ -n "$rest" ]; do
    case "$rest" in
      */*)
        seg="${rest%%/*}"
        rest="${rest#*/}"
        ;;
      *)
        seg="$rest"
        rest=""
        ;;
    esac
    if [ -z "$acc" ]; then
      acc="$seg"
    else
      acc="$acc/$seg"
    fi
    printf '%s\n' "$acc" >>"$out"
  done
}

# Returns 0 if remote dirs are ready (or nothing to create), 1 on SFTP failure.
_ensure_remote_flash_dirs_sftp() {
  local flash_root="$1"
  local dirs_tmp sorted_tmp batch d nf rel absfile disk_root

  disk_root="${ROUTER_FILES_DISK:-flash}"

  if [ "${MIKROTIK_UPLOAD_SKIP_SFTP_MKDIRS:-}" = "true" ]; then
    return 0
  fi

  dirs_tmp=$(mktemp)
  sorted_tmp=$(mktemp)
  batch=$(mktemp)

  : >"$dirs_tmp"
  while IFS= read -r -d '' absfile; do
    rel="${absfile#$MIKROTIK_SCP_FROM_DIR/}"
    rel="${rel#./}"
    _append_all_prefix_paths_of_dir "$(dirname "$rel")" "$dirs_tmp"
  done < <(find "$flash_root" -type f ! -name ".DS_Store" -print0)

  LC_ALL=C sort -u "$dirs_tmp" -o "$dirs_tmp"

  : >"$sorted_tmp"
  while IFS= read -r d; do
    [ -z "$d" ] || [ "$d" = "." ] && continue
    nf=$(printf '%s' "$d" | awk -F/ '{ printf "%04d", NF }')
    printf '%s\t%s\n' "$nf" "$d" >>"$sorted_tmp"
  done <"$dirs_tmp"

  LC_ALL=C sort "$sorted_tmp" -o "$sorted_tmp"

  : >"$batch"
  while IFS=$'\t' read -r _nf d; do
    local remote_d="$d"
    [ -z "$d" ] && continue
    if [ -n "$disk_root" ] && [ "$d" = "$disk_root" ]; then
      continue
    fi
    if [ -n "$SCP_REMOTE_PREFIX" ]; then
      remote_d="${SCP_REMOTE_PREFIX}/${d}"
      if [ "$remote_d" = "$disk_root" ]; then
        continue
      fi
    fi
    printf 'mkdir %s\n' "$remote_d" >>"$batch"
  done <"$sorted_tmp"

  rm -f "$dirs_tmp" "$sorted_tmp"

  if [ ! -s "$batch" ]; then
    rm -f "$batch"
    return 0
  fi

  printf "%s\n" "${BLUE}[INFO] Creating remote folders via SFTP (needed before single-file scp on RouterOS) ...${NC}"
  if _run_sftp_batch "$batch"; then
    rm -f "$batch"
    return 0
  fi
  rm -f "$batch"
  return 1
}

# Terminal width for single-line progress (ANSI carriage return + erase line; same pattern as wget/apt compact UI).
_terminal_cols() {
  local c
  if [ -n "${COLUMNS:-}" ]; then
    printf '%s' "$COLUMNS"
    return
  fi
  if [ -t 1 ] && command -v tput >/dev/null 2>&1; then
    c=$(tput cols 2>/dev/null) || c=""
    if [ -n "$c" ] && [ "$c" -gt 0 ] 2>/dev/null; then
      printf '%s' "$c"
      return
    fi
  fi
  printf '80'
}

# Middle-ellipsis path for fixed columns (bash 3.2–safe).
_truncate_path_middle() {
  local path="$1"
  local max="$2"
  local len=${#path}
  local inner left right start_pos

  if [ "$len" -le "$max" ]; then
    printf '%s' "$path"
    return
  fi
  inner=$((max - 3))
  left=$((inner / 2))
  right=$((inner - left))
  start_pos=$((len - right))
  printf '%s...%s' "${path:0:left}" "${path:start_pos}"
}

# Single updating line when stdout is a TTY; multiline when piping or MIKROTIK_UPLOAD_PROGRESS_MULTILINE=true.
_upload_flash_tree_with_progress() {
  local flash_root="$MIKROTIK_SCP_FROM_DIR/flash"
  local total i filled pct j bar bar_width rel absfile use_inline cols fname_max disp bar_fill bar_empty

  if [ ! -d "$flash_root" ]; then
    printf "%s\n" "${RED}[ERROR] Missing flash folder: ${flash_root}${NC}"
    exit 1
  fi

  use_inline=false
  if [ "${MIKROTIK_UPLOAD_PROGRESS_MULTILINE:-}" != "true" ] && [ -t 1 ]; then
    use_inline=true
  fi

  total=$(find "$flash_root" -type f ! -name ".DS_Store" | wc -l | tr -d ' ')
  if [ "${total:-0}" -eq 0 ]; then
    printf "%s\n" "${YELLOW}[WARNING] No files under ${flash_root}${NC}"
    return 0
  fi

  if ! _ensure_remote_flash_dirs_sftp "$flash_root"; then
    printf "%s\n" "${YELLOW}[WARNING] SFTP mkdir failed on the router; falling back to one recursive scp (no per-file progress).${NC}"
    if [ -n "$SCP_REMOTE_PREFIX" ]; then
      printf "%s\n" "${BLUE}[INFO] Uploading deployment/mikrotik/flash → ${USER_NAME}@${HOST}:/${SCP_REMOTE_PREFIX}/ ...${NC}"
      cd "$MIKROTIK_SCP_FROM_DIR"
      _run_scp -r flash "${USER_NAME}@${HOST}:/${SCP_REMOTE_PREFIX}/"
    else
      printf "%s\n" "${BLUE}[INFO] Uploading deployment/mikrotik/flash → ${USER_NAME}@${HOST}:/ ...${NC}"
      cd "$MIKROTIK_SCP_FROM_DIR"
      _run_scp -r flash "${USER_NAME}@${HOST}:/"
    fi
    return 0
  fi

  printf "%s\n" "${BLUE}[INFO] Uploading ${total} files under flash/ → ${REMOTE_HOTSPOT_PATH}/ on ${HOST} ...${NC}"
  bar_width=28
  if [ "${MIKROTIK_UPLOAD_PROGRESS_ASCII:-}" = "true" ]; then
    bar_fill='='
    bar_empty='-'
  else
    # UTF-8: █ (U+2588) filled, ░ (U+2591) empty — works in typical macOS/Linux terminals.
    bar_fill=$'\xe2\x96\x88'
    bar_empty=$'\xe2\x96\x91'
  fi
  i=0
  cd "$MIKROTIK_SCP_FROM_DIR"
  while IFS= read -r absfile; do
    i=$((i + 1))
    rel="${absfile#$MIKROTIK_SCP_FROM_DIR/}"
    rel="${rel#./}"

    filled=$((i * bar_width / total))
    if [ "$filled" -gt "$bar_width" ]; then
      filled=$bar_width
    fi
    pct=$((i * 100 / total))
    bar=""
    for ((j = 0; j < filled; j++)); do
      bar+="$bar_fill"
    done
    for ((j = filled; j < bar_width; j++)); do
      bar+="$bar_empty"
    done

    if [ "$use_inline" = true ]; then
      cols="$(_terminal_cols)"
      fname_max=$((cols - 54))
      if [ "$fname_max" -lt 24 ]; then
        fname_max=24
      fi
      disp="$(_truncate_path_middle "$rel" "$fname_max")"
      printf '\r\033[2K%s[INFO]%s [%s] %3d%% (%s/%s) %s' "${BLUE}" "${NC}" "$bar" "$pct" "$i" "$total" "$disp"
    else
      printf "${BLUE}[INFO]${NC} [%s] %3d%% (%s/%s) %s\n" "$bar" "$pct" "$i" "$total" "$rel"
    fi
    _run_scp "$rel" "$(_remote_scp_dest_for_rel "$rel")"
  done < <(find "$flash_root" -type f ! -name ".DS_Store" | LC_ALL=C sort)

  if [ "$use_inline" = true ]; then
    printf '\n'
  fi
}

cd "$MIKROTIK_SCP_FROM_DIR"
if [ "${MIKROTIK_UPLOAD_BULK:-}" = "true" ]; then
  printf "%s\n" "${BLUE}[INFO] MIKROTIK_UPLOAD_BULK=true — single recursive scp (no per-file progress).${NC}"
  if [ -n "$SCP_REMOTE_PREFIX" ]; then
    printf "%s\n" "${BLUE}[INFO] Uploading local deployment/mikrotik/flash → ${USER_NAME}@${HOST}:/${SCP_REMOTE_PREFIX}/ (remote ${REMOTE_HOTSPOT_PATH}/) ...${NC}"
    _run_scp -r flash "${USER_NAME}@${HOST}:/${SCP_REMOTE_PREFIX}/"
  else
    printf "%s\n" "${BLUE}[INFO] Uploading local deployment/mikrotik/flash → ${USER_NAME}@${HOST}:/ (remote ${REMOTE_HOTSPOT_PATH}/) ...${NC}"
    _run_scp -r flash "${USER_NAME}@${HOST}:/"
  fi
else
  _upload_flash_tree_with_progress
fi

printf "%s\n" "${GREEN}[SUCCESS] Upload finished. Verify in Winbox/WebFig under Files → ${REMOTE_HOTSPOT_PATH}/${NC}"

HS_DIR="${REMOTE_HOTSPOT_PATH}"
HS_DIR_ESC="${HS_DIR//\\/\\\\}"
HS_DIR_ESC="${HS_DIR_ESC//\"/\\\"}"
printf "%s\n" "${BLUE}[INFO] Setting hsprof1 html-directory=${HS_DIR} ...${NC}"
if _run_ssh "/ip hotspot profile set [find name=\"hsprof1\"] html-directory=\"${HS_DIR_ESC}\""; then
  printf "%s\n" "${GREEN}[SUCCESS] hsprof1 html-directory=${HS_DIR}${NC}"
else
  printf "%s\n" "${YELLOW}[WARNING] Could not set hsprof1 html-directory. Set it to ${HS_DIR} on the hotspot profile.${NC}"
fi
printf "%s\n" "${BLUE}[INFO] If pages look cached, restart the hotspot service or bump asset versions as needed.${NC}"
